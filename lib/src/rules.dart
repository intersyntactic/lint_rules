/// The rules of AGENTS.md's "Writing Dart" that a plugin can check.
///
/// None of them report in a package's test directories (`test/`,
/// `integration_test/`, `test_driver/`): see RULINGS.md.
library;

import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_system.dart';
import 'package:analyzer/error/error.dart';

/// Every rule the plugin registers.
final List<AnalysisRule> rules = [
  NoDynamic(),
  NoCastFromUntyped(),
  NoDefaultOnClosedType(),
  NoIgnoreComment(),
];

// ---------------------------------------------------------------- dynamic

/// Any `dynamic` written out. JSON arrives as `Object?`.
class NoDynamic extends AnalysisRule {
  static const code = LintCode(
    'no_dynamic',
    "Don't write `dynamic`.",
    correctionMessage: 'JSON arrives as Object?; narrow it with a pattern.',
  );

  NoDynamic() : super(name: 'no_dynamic', description: 'No written dynamic.');

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry r, RuleContext c) {
    if (c.isInTestDirectory) return;
    r.addNamedType(this, _NoDynamic(this));
  }
}

class _NoDynamic extends SimpleAstVisitor<void> {
  _NoDynamic(this.rule);
  final AnalysisRule rule;

  @override
  void visitNamedType(NamedType node) {
    if (node.name.lexeme == 'dynamic') rule.reportAtNode(node);
  }
}

// ---------------------------------------------------------------- casts

/// `as` on a value whose type says nothing: `dynamic`, `Object` or `Object?`,
/// a type parameter bounded by one, or a generic whose arguments are one
/// (`List<Object?>`). That is what JSON, a map lookup, an isolate message and
/// `ProcessResult.stdout` arrive as.
///
/// A cast with a reason is allowed: `// cast-ok: <why>` on its line or the
/// line above.
class NoCastFromUntyped extends AnalysisRule {
  static const code = LintCode(
    'no_cast_from_untyped',
    'Narrowing an untyped value with `as` or `.cast`.',
    correctionMessage:
        'Use a pattern (`case final String s`) or JsonFields, which name the '
        'field when it is wrong. If a cast is really right here, write '
        '`// cast-ok: <why>` on or above the line.',
  );

  NoCastFromUntyped()
    : super(
        name: 'no_cast_from_untyped',
        description: 'No as on dynamic, Object? or a generic of them.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry r, RuleContext c) {
    if (c.isInTestDirectory) return;
    final v = _NoCast(this, c);
    r.addAsExpression(this, v);
    r.addMethodInvocation(this, v);
  }
}

/// Whether [t] carries no type information a reader can rely on.
///
/// [seen] holds the type parameters already being looked through, so a bound
/// that leads back to its own parameter (`T extends Comparable<T>`) ends
/// instead of recursing: a parameter met again adds nothing new.
bool _untyped(DartType t, [Set<TypeParameterElement> seen = const {}]) =>
    switch (t) {
      DynamicType() => true,
      TypeParameterType(:final element, :final bound) =>
        !seen.contains(element) && _untyped(bound, {...seen, element}),
      InterfaceType(:final typeArguments) =>
        t.isDartCoreObject || typeArguments.any((a) => _untyped(a, seen)),
      _ => false,
    };

/// A `// cast-ok:` comment followed by a reason.
final _castOk = RegExp(r'^//\s*cast-ok:\s*\S');

class _NoCast extends SimpleAstVisitor<void> {
  _NoCast(this.rule, this.context);
  final AnalysisRule rule;
  final RuleContext context;

  /// The lines (0-based) of the unit [_linesOf] that hold a `cast-ok:`
  /// comment, found once per unit.
  CompilationUnit? _linesOf;
  Set<int> _okLines = const {};

  @override
  void visitAsExpression(AsExpression node) {
    final from = node.expression.staticType;
    if (from == null || !_untyped(from)) return;
    if (_hasReason(node, node.asOperator.offset)) return;
    rule.reportAtNode(node);
  }

  /// `.cast<R>()` on a value whose type arguments say nothing
  /// (`List<Object?>`, `Map<dynamic, dynamic>`): the same unchecked
  /// narrowing as `as`, one element at a time. The `<R>` may be written or
  /// inferred.
  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name != 'cast') return;
    final from = node.realTarget?.staticType;
    final untyped = switch (from) {
      DynamicType() => true,
      InterfaceType(:final typeArguments) => typeArguments.any(_untyped),
      _ => false,
    };
    if (!untyped) return;
    if (_hasReason(node, node.methodName.offset)) return;
    rule.reportAtNode(node);
  }

  /// Whether the line holding [offset] in [node]'s unit, or the line above
  /// it, has a `// cast-ok: <why>` comment. Comments are read as tokens, so
  /// the words in a string literal are not one.
  bool _hasReason(AstNode node, int offset) {
    final unit = node.root;
    if (unit is! CompilationUnit) return false;
    if (!identical(unit, _linesOf)) {
      _linesOf = unit;
      _okLines = {
        for (final c in _comments(unit))
          if (_castOk.hasMatch(c.lexeme))
            unit.lineInfo.getLocation(c.offset).lineNumber - 1,
      };
    }
    final line = unit.lineInfo.getLocation(offset).lineNumber - 1;
    return _okLines.contains(line) || _okLines.contains(line - 1);
  }
}

/// Every comment in [unit]. Comments hang off the token after them; the ones
/// at the end of the file hang off EOF, which the walk reaches last.
Iterable<Token> _comments(CompilationUnit unit) sync* {
  Token? t = unit.beginToken;
  while (true) {
    for (Token? c = t?.precedingComments; c != null; c = c.next) {
      yield c;
    }
    if (t == null || t.isEof) return;
    t = t.next;
  }
}

// ---------------------------------------------------------------- catch-alls

/// `default` or `_` in a switch on an enum or a sealed class. Naming every
/// case makes the next one added fail to compile until the switch handles it.
class NoDefaultOnClosedType extends AnalysisRule {
  static const code = LintCode(
    'no_default_on_closed_type',
    'A catch-all on {0} hides the next case added to it.',
    correctionMessage: 'Name every case, so a new one fails to compile here.',
  );

  NoDefaultOnClosedType()
    : super(
        name: 'no_default_on_closed_type',
        description: 'No default or _ on an enum or sealed type.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry r, RuleContext c) {
    if (c.isInTestDirectory) return;
    final v = _NoDefault(this, c.typeSystem);
    r.addSwitchStatement(this, v);
    r.addSwitchExpression(this, v);
  }
}

class _NoDefault extends SimpleAstVisitor<void> {
  _NoDefault(this.rule, this.types);
  final AnalysisRule rule;
  final TypeSystem types;

  /// The enum or sealed class [t] is, by name; null when it is open. A type
  /// parameter is what its bound is: `T extends E` is closed when `E` is.
  String? _closed(DartType? t) => switch (t) {
    TypeParameterType(:final bound) => _closed(bound),
    _ => switch (t?.element) {
      final EnumElement e => 'enum ${e.name}',
      final ClassElement c when c.isSealed => 'sealed ${c.name}',
      _ => null,
    },
  };

  /// An unguarded case that every value of the closed type matches, however
  /// it is spelled: `_`, `final other`, `var x`, `E _`, `S()` or `S(:final x)`
  /// on an `S`, or an `||` or `&&` built of them. A `null` arm beside it does
  /// not change that: the case still takes every value of the type itself.
  bool _isCatchAll(GuardedPattern g, DartType of) =>
      g.whenClause == null &&
      _matchesAll(g.pattern, types.promoteToNonNull(of));

  bool _matchesAll(DartPattern p, DartType of) => switch (p) {
    WildcardPattern(:final type) => _covers(type, of),
    DeclaredVariablePattern(:final type) => _covers(type, of),
    ObjectPattern(:final type, :final fields) =>
      _covers(type, of) && fields.every((f) => _takesAnything(f.pattern)),
    ParenthesizedPattern(:final pattern) => _matchesAll(pattern, of),
    LogicalOrPattern(:final leftOperand, :final rightOperand) =>
      _matchesAll(leftOperand, of) || _matchesAll(rightOperand, of),
    LogicalAndPattern(:final leftOperand, :final rightOperand) =>
      _matchesAll(leftOperand, of) && _matchesAll(rightOperand, of),
    // Each of these tests the value, or (`as`, `!`) throws for some of it. An
    // `as` to a type every value already is (`final x as S` on an S) would
    // match all, but the analyzer reports it as unnecessary_cast_pattern,
    // which --fatal-infos fails, so it is not counted twice here.
    AssignedVariablePattern() ||
    CastPattern() ||
    ConstantPattern() ||
    ListPattern() ||
    MapPattern() ||
    NullAssertPattern() ||
    NullCheckPattern() ||
    RecordPattern() ||
    RelationalPattern() => false,
  };

  /// A field's pattern that checks nothing about the field: `_`, or a
  /// variable with no type written.
  bool _takesAnything(DartPattern p) =>
      (p is WildcardPattern && p.type == null) ||
      (p is DeclaredVariablePattern && p.type == null) ||
      (p is ParenthesizedPattern && _takesAnything(p.pattern));

  /// Whether a pattern typed [annotation] (none: any) takes every [of].
  bool _covers(TypeAnnotation? annotation, DartType of) =>
      switch (annotation?.type) {
        null => annotation == null,
        final t => types.isSubtypeOf(of, t),
      };

  @override
  void visitSwitchStatement(SwitchStatement node) {
    final of = node.expression.staticType;
    final closed = _closed(of);
    if (of == null || closed == null) return;
    for (final m in node.members) {
      if (m is SwitchDefault ||
          (m is SwitchPatternCase && _isCatchAll(m.guardedPattern, of))) {
        rule.reportAtNode(m, arguments: [closed]);
      }
    }
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    final of = node.expression.staticType;
    final closed = _closed(of);
    if (of == null || closed == null) return;
    for (final c in node.cases) {
      if (_isCatchAll(c.guardedPattern, of)) {
        rule.reportAtNode(c, arguments: [closed]);
      }
    }
  }
}

// ---------------------------------------------------------------- ignores

/// Any `// ignore:` or `// ignore_for_file:`, including the
/// `// ignore: lint_rules/<rule>` that would silence these rules.
class NoIgnoreComment extends AnalysisRule {
  static const code = LintCode(
    'no_ignore_comment',
    'An `// ignore:` silences the analyzer.',
    correctionMessage: 'Fix the type instead.',
  );

  NoIgnoreComment()
    : super(name: 'no_ignore_comment', description: 'No ignore comments.');

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry r, RuleContext c) {
    if (c.isInTestDirectory) return;
    r.addCompilationUnit(this, _NoIgnore(this));
  }
}

final _ignore = RegExp(r'^//\s*ignore(_for_file)?\s*:');

class _NoIgnore extends SimpleAstVisitor<void> {
  _NoIgnore(this.rule);
  final AnalysisRule rule;

  @override
  void visitCompilationUnit(CompilationUnit node) {
    for (final c in _comments(node)) {
      if (_ignore.hasMatch(c.lexeme)) rule.reportAtToken(c);
    }
  }
}
