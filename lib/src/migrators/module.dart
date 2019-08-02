// Copyright 2019 Google LLC
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'package:args/args.dart';

// The sass package's API is not necessarily stable. It is being imported with
// the Sass team's explicit knowledge and approval. See
// https://github.com/sass/dart-sass/issues/236.
import 'package:sass/src/ast/sass.dart';

import 'package:path/path.dart' as p;
import 'package:source_span/source_span.dart';

import '../migration_visitor.dart';
import '../migrator.dart';
import '../patch.dart';
import '../utils.dart';

import 'module/built_in_functions.dart';
import 'module/forward_type.dart';
import 'module/scope.dart';
import 'module/unreferencable_type.dart';

/// Migrates stylesheets to the new module system.
class ModuleMigrator extends Migrator {
  final name = "module";
  final description = "Migrates stylesheets to the new module system.";

  @override
  final argParser = ArgParser()
    ..addOption('remove-prefix',
        abbr: 'p', help: 'Removes the provided prefix from members.')
    ..addOption('forward',
        allowed: ['all', 'none', 'prefixed'],
        allowedHelp: {
          'none': "Doesn't forward any members.",
          'prefixed':
              'Forwards members that start with the prefix specified for '
                  '--remove-prefix.',
          'all': 'Forwards all members.'
        },
        defaultsTo: 'none',
        help: 'Specifies which members from dependencies to forward from the '
            'entrypoint.');

  // Hide this until it's finished and the module system is launched.
  final hidden = true;

  /// Runs the module migrator on [entrypoint] and its dependencies and returns
  /// a map of migrated contents.
  ///
  /// If [migrateDependencies] is false, the migrator will still be run on
  /// dependencies, but they will be excluded from the resulting map.
  Map<Uri, String> migrateFile(Uri entrypoint) {
    var forward = ForwardType(argResults['forward']);
    if (forward == ForwardType.prefixed &&
        argResults['remove-prefix'] == null) {
      throw MigrationException(
          'You must provide --remove-prefix with --forward=prefixed so we know '
          'which prefixed members to forward.');
    }
    var migrated = _ModuleMigrationVisitor(
            prefixToRemove:
                (argResults['remove-prefix'] as String)?.replaceAll('_', '-'),
            forward: forward)
        .run(entrypoint);
    if (!migrateDependencies) {
      migrated.removeWhere((url, contents) => url != entrypoint);
    }
    return migrated;
  }
}

class _ModuleMigrationVisitor extends MigrationVisitor {
  /// The scope containing all variables, mixins, and functions defined in the
  /// current context.
  var _scope = Scope();

  /// Stores whether a given VariableDeclaration has been referenced in an
  /// expression after being declared.
  final _referencedVariables = <VariableDeclaration>{};

  /// Set of stylesheets currently being migrated.
  ///
  /// Used to ensure that a dependency declaring a variable that an upstream
  /// stylesheet already declared is not treated as reassignment (since that
  /// would cause a circular dependency).
  final _upstreamStylesheets = <Uri>{};

  /// Namespaces of modules used in this stylesheet.
  Map<Uri, String> _namespaces;

  /// Set of additional use rules necessary for referencing members of
  /// implicit dependencies / built-in modules.
  ///
  /// This set contains the path provided in the use rule, not the canonical
  /// path (e.g. "a" rather than "dir/a.scss").
  Set<String> _additionalUseRules;

  /// Set of variables declared outside the current stylesheet that overrode
  /// `!default` variables within the current stylesheet.
  Set<VariableDeclaration> _configuredVariables;

  /// Whether @use and @forward are allowed in the current context.
  var _useAllowed = true;

  /// The URL of the current stylesheet.
  Uri _currentUrl;

  /// The URL of the last stylesheet that was completely migrated.
  Uri _lastUrl;

  /// The prefix to be removed from any members with it, or null if no prefix
  /// should be removed.
  final String prefixToRemove;

  /// The value of the --forward flag.
  final ForwardType forward;

  /// Constructs a new module migration visitor.
  ///
  /// Note: We always set [migratedDependencies] to true since the module
  /// migrator needs to always run on dependencies. The `migrateFile` method of
  /// the module migrator will filter out the dependencies' migration results.
  _ModuleMigrationVisitor({this.prefixToRemove, this.forward})
      : super(migrateDependencies: true);

  /// Returns a semicolon unless the current stylesheet uses the indented
  /// syntax, in which case this returns an empty string.
  String get _semicolonIfNotIndented =>
      _currentUrl.path.endsWith('.sass') ? "" : ";";

  /// Returns the migrated contents of this stylesheet, based on [patches] and
  /// [_additionalUseRules], or null if the stylesheet does not change.
  @override
  String getMigratedContents() {
    var results = super.getMigratedContents();
    if (results == null) return null;
    var uses = _additionalUseRules
        .map((use) => '@use "$use"$_semicolonIfNotIndented\n');
    return _getEntrypointForwards() + uses.join() + results;
  }

  /// Returns whether the member named [name] should be forwarded in the
  /// entrypoint.
  ///
  /// [name] should be the original name of that member, even if it started with
  /// [prefixToRemove].
  bool _shouldForward(String name) {
    switch (forward) {
      case ForwardType.all:
        return true;
      case ForwardType.none:
        return false;
      case ForwardType.prefixed:
        return name.startsWith(prefixToRemove);
      default:
        throw StateError('--forward should not allow invalid values');
    }
  }

  /// If the current stylesheet is the entrypoint, return a string of @forward
  /// rules to forward all members for which [_shouldForward] returns true.
  String _getEntrypointForwards() {
    if (!_scope.isGlobal) {
      throw StateError('Must be called from root of stylesheet');
    }
    if (_upstreamStylesheets.isNotEmpty) return '';

    // Divide all global members from dependencies into sets based on whether
    // they should be forwarded or not.
    var shown = <Uri, Set<String>>{};
    var hidden = <Uri, Set<String>>{};
    categorizeMember(Uri url, String originalName, String newName) {
      if (url == _currentUrl) return;
      if (_shouldForward(originalName)) {
        shown[url] ??= {};
        shown[url].add(newName);
      } else {
        hidden[url] ??= {};
        hidden[url].add(newName);
      }
    }

    for (var entry in _scope.variables.entries) {
      if (entry.value is! VariableDeclaration) continue;
      categorizeMember(entry.value.span.sourceUrl,
          (entry.value as VariableDeclaration).name, '\$${entry.key}');
    }
    for (var entry in _scope.mixins.entries) {
      categorizeMember(entry.value.span.sourceUrl, entry.value.name, entry.key);
    }
    for (var entry in _scope.functions.entries) {
      categorizeMember(entry.value.span.sourceUrl, entry.value.name, entry.key);
    }

    // Create a @forward rule for each dependency that has members that should
    // be forwarded.
    var forwards = <String>[];
    for (var url in shown.keys) {
      var hiddenCount = hidden[url]?.length ?? 0;
      var forward = '@forward "${_absoluteUrlToDependency(url)}"';

      // When not all members from a dependency should be forwarded, use a
      // `hide` clause to hide the ones that shouldn't.
      if (hiddenCount > 0) {
        var hiddenMembers = hidden[url].toList()..sort();
        forward += ' hide ${hiddenMembers.join(", ")}';
      }
      forward += '$_semicolonIfNotIndented\n';
      forwards.add(forward);
    }
    forwards.sort();
    return forwards.join('');
  }

  /// Visits the stylesheet at [dependency], resolved relative to [source].
  @override
  void visitDependency(Uri dependency, Uri source, [FileSpan context]) {
    var url = source.resolveUri(dependency);
    var stylesheet = parseStylesheet(url);
    if (stylesheet == null) {
      throw MigrationException(
          "Error: Could not find Sass file at '${p.prettyUri(url)}'.",
          span: context);
    }

    visitStylesheet(stylesheet);
  }

  /// Stores per-file state before visiting [node] and restores it afterwards.
  @override
  void visitStylesheet(Stylesheet node) {
    var oldNamespaces = _namespaces;
    var oldAdditionalUseRules = _additionalUseRules;
    var oldUrl = _currentUrl;
    var oldUseAllowed = _useAllowed;
    _namespaces = {};
    _additionalUseRules = Set();
    _currentUrl = node.span.sourceUrl;
    _useAllowed = true;
    super.visitStylesheet(node);
    _namespaces = oldNamespaces;
    _additionalUseRules = oldAdditionalUseRules;
    _lastUrl = _currentUrl;
    _currentUrl = oldUrl;
    _useAllowed = oldUseAllowed;
  }

  /// Visits each of [node]'s expressions and children.
  ///
  /// All of [node]'s arguments are declared as local variables in a new scope.
  @override
  void visitCallableDeclaration(CallableDeclaration node) {
    _scope = Scope(_scope);
    for (var argument in node.arguments.arguments) {
      _scope.variables[argument.name] = argument;
      if (argument.defaultValue != null) visitExpression(argument.defaultValue);
    }
    super.visitChildren(node);
    _scope = _scope.parent;
  }

  /// Visits the children of [node] with a local scope.
  ///
  /// Note: The children of a stylesheet are at the root, so we should not add
  /// a local scope.
  @override
  void visitChildren(ParentStatement node) {
    if (node is Stylesheet) {
      super.visitChildren(node);
      return;
    }
    _scope = Scope(_scope);
    super.visitChildren(node);
    _scope = _scope.parent;
  }

  /// Adds a namespace to any function call that requires it.
  @override
  void visitFunctionExpression(FunctionExpression node) {
    visitInterpolation(node.name);
    _scope.checkUnreferencableFunction(node);
    _patchNamespaceForFunction(node, node.name.asPlain, (name, namespace) {
      addPatch(
          Patch(node.name.span, namespace == null ? name : "$namespace.$name"));
    });
    visitArgumentInvocation(node.arguments);

    if (node.name.asPlain == "get-function") {
      var nameArgument =
          node.arguments.named['name'] ?? node.arguments.positional.first;
      if (nameArgument is! StringExpression ||
          (nameArgument as StringExpression).text.asPlain == null) {
        emitWarning("get-function call may require \$module parameter",
            nameArgument.span);
        return;
      }
      var fnName = nameArgument as StringExpression;
      _patchNamespaceForFunction(node, fnName.text.asPlain, (name, namespace) {
        var span = fnName.span;
        if (fnName.hasQuotes) {
          span = span.file.span(span.start.offset + 1, span.end.offset - 1);
        }
        addPatch(Patch(span, name));
        var beforeParen = node.span.end.offset - 1;
        if (namespace != null) {
          addPatch(Patch(node.span.file.span(beforeParen, beforeParen),
              ', \$module: "$namespace"'));
        }
      });
    }
  }

  /// Calls [patcher] when the function [node] with name [originalName] requires
  /// a namespace and/or a new name and adds a new use rule if necessary.
  ///
  /// When the function is a color function that's not present in the module
  /// system (like `lighten`), this also migrates its `$amount` argument to the
  /// appropriate `color.adjust` argument.
  ///
  /// [patcher] takes two arguments: the name used to refer to that function
  /// when namespaced, and the namespace itself. The name will match the name
  /// provided to the outer function except for built-in functions whose name
  /// within a module differs from its original name.
  void _patchNamespaceForFunction(FunctionExpression node, String originalName,
      void patcher(String name, String namespace)) {
    if (originalName == null) return;
    if (_scope.isLocalFunction(originalName)) return;

    var name = _unprefix(originalName) ?? originalName;

    var namespace = _scope.global.functions.containsKey(name)
        ? _namespaceForNode(_scope.global.functions[name])
        : null;

    if (namespace == null && builtInFunctionModules.containsKey(name)) {
      // Don't migrate CSS-compatibility overloads.
      if (_isCssCompatibilityOverload(node)) return;

      namespace = builtInFunctionModules[name];
      name = builtInFunctionNameChanges[name] ?? name;
      if (namespace == 'color' && removedColorFunctions.containsKey(name)) {
        if (node.arguments.positional.length == 2 &&
            node.arguments.named.isEmpty) {
          _patchRemovedColorFunction(name, node.arguments.positional.last);
          name = 'adjust';
        } else if (node.arguments.named.containsKey('amount')) {
          var arg = node.arguments.named['amount'];
          _patchRemovedColorFunction(name, arg,
              existingArgName: _findArgNameSpan(arg));
          name = 'adjust';
        } else {
          emitWarning("Could not migrate malformed '$name' call", node.span);
          return;
        }
      }
      _additionalUseRules.add("sass:$namespace");
    }
    if (namespace != null || name != originalName) patcher(name, namespace);
  }

  /// Returns true if [node] is a function overload that exists to provide
  /// compatiblity with plain CSS function calls, and should therefore not be
  /// migrated to the module version.
  bool _isCssCompatibilityOverload(FunctionExpression node) {
    var argument = getOnlyArgument(node.arguments);
    switch (node.name.asPlain) {
      case 'grayscale':
      case 'invert':
      case 'opacity':
        return argument is NumberExpression;
      case 'saturate':
        return argument != null;
      case 'alpha':
        var totalArgs =
            node.arguments.positional.length + node.arguments.named.length;
        if (totalArgs > 1) return true;
        return argument is BinaryOperationExpression &&
            argument.operator == BinaryOperator.singleEquals;
      default:
        return false;
    }
  }

  /// Given a named argument [arg], returns a span from the start of the name
  /// to the start of the argument itself (e.g. "$amount: ").
  FileSpan _findArgNameSpan(Expression arg) {
    var start = arg.span.start.offset - 1;
    while (arg.span.file.getText(start, start + 1) != r'$') {
      start--;
    }
    return arg.span.file.span(start, arg.span.start.offset);
  }

  /// Patches the amount argument [arg] for a removed color function
  /// (e.g. `lighten`) to add the appropriate name (such as `$lightness`) and
  /// negate the argument if necessary.
  void _patchRemovedColorFunction(String name, Expression arg,
      {FileSpan existingArgName}) {
    var parameter = removedColorFunctions[name];
    var needsParens =
        parameter.endsWith('-') && arg is BinaryOperationExpression;
    var leftParen = needsParens ? '(' : '';
    if (existingArgName == null) {
      addPatch(patchBefore(arg, '$parameter$leftParen'));
    } else {
      addPatch(Patch(existingArgName, '$parameter$leftParen'));
    }
    if (needsParens) addPatch(patchAfter(arg, ')'));
  }

  /// Declares the function within the current scope before visiting it.
  @override
  void visitFunctionRule(FunctionRule node) {
    _useAllowed = false;
    _declareFunction(node);
    super.visitFunctionRule(node);
  }

  /// Migrates @import to @use after migrating the imported file.
  @override
  void visitImportRule(ImportRule node) {
    if (node.imports.first is StaticImport) {
      _useAllowed = false;
      super.visitImportRule(node);
      return;
    }
    if (node.imports.length > 1) {
      throw UnimplementedError(
          "Migration of @import rule with multiple imports not supported.");
    }
    var import = node.imports.first as DynamicImport;
    var migrateToLoadCss = _scope.parent != null || !_useAllowed;

    var oldConfiguredVariables = _configuredVariables;
    _configuredVariables = Set();
    _upstreamStylesheets.add(_currentUrl);

    var oldScope = _scope;
    if (migrateToLoadCss) {
      _scope = oldScope.copyForNestedImport();
      var current = oldScope.parent;
      while (current != null) {
        _scope.variables.addAll(current.variables);
        current = current.parent;
      }
    }
    visitDependency(Uri.parse(import.url), _currentUrl, import.span);
    _upstreamStylesheets.remove(_currentUrl);
    if (migrateToLoadCss) {
      oldScope.addAllMembers(_scope.global,
          unreferencable: UnreferencableType.globalFromNestedImport);
      _scope = oldScope;
    } else {
      _namespaces[_lastUrl] = namespaceForPath(import.url);
    }

    // Pass the variables that were configured by the importing file to `with`,
    // and forward the rest and add them to `oldConfiguredVariables` because
    // they were configured by a further-out import.
    var locallyConfiguredVariables = <String, VariableDeclaration>{};
    var externallyConfiguredVariables = <String, VariableDeclaration>{};
    for (var variable in _configuredVariables) {
      if (variable.span.sourceUrl == _currentUrl) {
        locallyConfiguredVariables[variable.name] = variable;
      } else {
        externallyConfiguredVariables[variable.name] = variable;
        oldConfiguredVariables.add(variable);
      }
    }
    _configuredVariables = oldConfiguredVariables;

    if (externallyConfiguredVariables.isNotEmpty) {
      if (migrateToLoadCss) {
        var firstConfig = externallyConfiguredVariables.values.first;
        throw MigrationException(
            "This declaration attempts to override a default value in an "
            "indirect, nested import of ${p.prettyUri(_lastUrl)}, which is "
            "not possible in the module system.",
            span: firstConfig.span);
      }
      addPatch(patchBefore(
          node,
          "@forward ${import.span.text} show " +
              externallyConfiguredVariables.keys
                  .map((variable) => "\$$variable")
                  .join(", ") +
              "$_semicolonIfNotIndented\n"));
    }

    var configuration = "";
    var configured = <String>[];
    for (var name in locallyConfiguredVariables.keys) {
      var variable = locallyConfiguredVariables[name];
      if (variable.isGuarded || _referencedVariables.contains(variable)) {
        configured.add("\$$name: \$$name");
      } else {
        // TODO(jathak): Handle the case where the expression of this
        // declaration has already been patched.
        var before = variable.span.start.offset;
        var beforeDeclaration = variable.span.file
            .span(before - variable.span.start.column, before);
        if (beforeDeclaration.text.trim() == '') {
          addPatch(patchDelete(beforeDeclaration));
        }
        addPatch(patchDelete(variable.span));
        var start = variable.span.end.offset;
        var end = start + _semicolonIfNotIndented.length;
        if (variable.span.file.span(end, end + 1).text == '\n') end++;
        addPatch(patchDelete(variable.span.file.span(start, end)));
        var nameFormat = migrateToLoadCss ? '"$name"' : '\$$name';
        configured.add("$nameFormat: ${variable.expression}");
      }
    }
    if (configured.length == 1) {
      configuration = " with (" + configured.first + ")";
    } else if (configured.isNotEmpty) {
      var indent = ' ' * node.span.start.column;
      configuration =
          " with (\n$indent  " + configured.join(',\n$indent  ') + "\n$indent)";
    }
    if (migrateToLoadCss) {
      _additionalUseRules.add('sass:meta');
      configuration = configuration.replaceFirst(' with', r', $with:');
      addPatch(Patch(node.span,
          '@include meta.load-css(${import.span.text}$configuration)'));
    } else {
      addPatch(Patch(node.span, '@use ${import.span.text}$configuration'));
    }
  }

  /// Adds a namespace to any mixin include that requires it.
  @override
  void visitIncludeRule(IncludeRule node) {
    _useAllowed = false;
    super.visitIncludeRule(node);
    _scope.checkUnreferencableMixin(node);
    if (_scope.isLocalMixin(node.name)) return;

    var name = _unprefix(node.name);
    if (!_scope.global.mixins.containsKey(name)) return;

    var namespace = _namespaceForNode(_scope.global.mixins[name]);
    var endName = node.arguments.span.start.offset;
    var startName = endName - node.name.length;
    var nameSpan = node.span.file.span(startName, endName);
    if (namespace == null) {
      if (name != node.name) addPatch(Patch(nameSpan, name));
    } else {
      addPatch(Patch(nameSpan, "$namespace.$name"));
    }
  }

  /// Declares the mixin within the current scope before visiting it.
  @override
  void visitMixinRule(MixinRule node) {
    _useAllowed = false;
    _declareMixin(node);
    super.visitMixinRule(node);
  }

  @override
  void visitUseRule(UseRule node) {
    // TODO(jathak): Handle existing @use rules.
    throw UnsupportedError(
        "Migrating files with existing @use rules is not yet supported");
  }

  /// Adds a namespace to any variable that requires it.
  @override
  void visitVariableExpression(VariableExpression node) {
    _scope.checkUnreferencableVariable(node);
    if (_scope.isLocalVariable(node.name)) return;

    var name = _unprefix(node.name);
    if (!_scope.global.variables.containsKey(name)) return;
    var declaration = _scope.global.variables[name];

    _referencedVariables.add(declaration);
    var namespace = _namespaceForNode(declaration);
    if (namespace == null) {
      if (name != node.name) addPatch(Patch(node.span, "\$$name"));
    } else {
      addPatch(Patch(node.span, "\$$namespace.$name"));
    }
  }

  /// Declares a variable within the current scope before visiting it.
  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    _declareVariable(node);
    super.visitVariableDeclaration(node);
  }

  /// Declares a variable within this stylesheet, in the current local scope if
  /// it exists, or as a global variable otherwise.
  void _declareVariable(VariableDeclaration node) {
    var name = node.name;
    if (_scope.isGlobal || node.isGlobal) {
      name = _unprefix(node.name);
      if (name != node.name) {
        addPatch(
            patchDelete(node.span, start: 1, end: prefixToRemove.length + 1));
      }
      var existingNode = _scope.global.variables[name];
      var originalUrl = existingNode?.span?.sourceUrl;
      if (existingNode != null && originalUrl != _currentUrl) {
        if (node.isGuarded) {
          _configuredVariables.add(existingNode);
        } else if (!_upstreamStylesheets.contains(originalUrl)) {
          // This declaration reassigns a variable in another module. Since we
          // don't care about the actual value of the variable while migrating,
          // we leave the node in _scope.global.variables as-is, so that future
          // references namespace based on the original declaration, not this
          // reassignment.
          var namespace = _namespaceForNode(existingNode);
          var afterDollarSign = node.span.start.offset + 1;
          addPatch(Patch(node.span.file.span(afterDollarSign, afterDollarSign),
              '$namespace.'));
          return;
        }
      }
    }
    _scope.variables[name] = node;
  }

  /// Declares a mixin within this stylesheet, in the current local scope if
  /// it exists, or as a global mixin otherwise.
  void _declareMixin(MixinRule node) {
    var name = node.name;
    if (_scope.isGlobal) {
      name = _unprefix(node.name);
      if (name != node.name) {
        var nameStart = node.span.text
            .indexOf(node.name, node.span.text[0] == '=' ? 1 : '@mixin'.length);
        addPatch(patchDelete(node.span,
            start: nameStart, end: nameStart + prefixToRemove.length));
      }
    }
    _scope.mixins[name] = node;
  }

  /// Declares a function within this stylesheet, in the current local scope if
  /// it exists, or as a global function otherwise.
  void _declareFunction(FunctionRule node) {
    var name = node.name;
    if (_scope.isGlobal) {
      name = _unprefix(node.name);
      if (name != node.name) {
        var nameStart = node.span.text.indexOf(node.name, '@function'.length);
        addPatch(patchDelete(node.span,
            start: nameStart, end: nameStart + prefixToRemove.length));
      }
    }
    _scope.functions[name] = node;
  }

  /// Returns [name] with [prefixToRemove] removed.
  String _unprefix(String name) {
    if (prefixToRemove == null || prefixToRemove.length > name.length) {
      return name;
    }
    var startOfName = name.substring(0, prefixToRemove.length);
    if (prefixToRemove != startOfName) return name;
    return name.substring(prefixToRemove.length);
  }

  /// Finds the namespace for the stylesheet containing [node], adding a new use
  /// rule if necessary.
  String _namespaceForNode(SassNode node) {
    if (node.span.sourceUrl == _currentUrl) return null;
    if (!_namespaces.containsKey(node.span.sourceUrl)) {
      /// Add new use rule for indirect dependency
      var simplePath = _absoluteUrlToDependency(node.span.sourceUrl);
      _additionalUseRules.add(simplePath);
      _namespaces[node.span.sourceUrl] = namespaceForPath(simplePath);
    }
    return _namespaces[node.span.sourceUrl];
  }

  /// Converts an absolute URL for a stylesheet into the simplest string that
  /// could be used to depend on that stylesheet from the current one in a use,
  /// forward, or import rule.
  String _absoluteUrlToDependency(Uri uri) {
    var relativePath =
        p.url.relative(uri.path, from: p.url.dirname(_currentUrl.path));
    var basename = p.url.basenameWithoutExtension(relativePath);
    if (basename.startsWith('_')) basename = basename.substring(1);
    return p.url.relative(p.url.join(p.url.dirname(relativePath), basename));
  }

  /// Disallows @use after @at-root rules.
  @override
  void visitAtRootRule(AtRootRule node) {
    _useAllowed = false;
    super.visitAtRootRule(node);
  }

  /// Disallows @use after at-rules.
  @override
  void visitAtRule(AtRule node) {
    _useAllowed = false;
    super.visitAtRule(node);
  }

  /// Disallows @use after @debug rules.
  @override
  void visitDebugRule(DebugRule node) {
    _useAllowed = false;
    super.visitDebugRule(node);
  }

  /// Disallows @use after @each rules.
  @override
  void visitEachRule(EachRule node) {
    _useAllowed = false;
    super.visitEachRule(node);
  }

  /// Disallows @use after @error rules.
  @override
  void visitErrorRule(ErrorRule node) {
    _useAllowed = false;
    super.visitErrorRule(node);
  }

  /// Disallows @use after @for rules.
  @override
  void visitForRule(ForRule node) {
    _useAllowed = false;
    super.visitForRule(node);
  }

  /// Disallows @use after @if rules.
  @override
  void visitIfRule(IfRule node) {
    _useAllowed = false;
    super.visitIfRule(node);
  }

  /// Disallows @use after @media rules.
  @override
  void visitMediaRule(MediaRule node) {
    _useAllowed = false;
    super.visitMediaRule(node);
  }

  /// Disallows @use after style rules.
  @override
  void visitStyleRule(StyleRule node) {
    _useAllowed = false;
    super.visitStyleRule(node);
  }

  /// Disallows @use after @supports rules.
  @override
  void visitSupportsRule(SupportsRule node) {
    _useAllowed = false;
    super.visitSupportsRule(node);
  }

  /// Disallows @use after @warn rules.
  @override
  void visitWarnRule(WarnRule node) {
    _useAllowed = false;
    super.visitWarnRule(node);
  }

  /// Disallows @use after @while rules.
  @override
  void visitWhileRule(WhileRule node) {
    _useAllowed = false;
    super.visitWhileRule(node);
  }
}
