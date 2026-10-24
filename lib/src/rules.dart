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

/// `as` on a value whose type says nothing: `dynamic`, `Object?`, a type
/// parameter bounded by one, or a generic whose arguments are one
/// (`List<Object?>`). That is what JSON, a map lookup, an isolate message and
/// `ProcessResult.stdout` arrive as.
///
/// A cast with a reason is allowed: `// cast-ok: <why>` on its line or the
/// line above.
class NoCastFromUntyped extends AnalysisRule {
  static const code = LintCode(
    'no_cast_from_untyped',
    'Narrowing an untyped value with `as`.',
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
    r.addAsExpression(this, _NoCast(this, c));
  }
}

/// Whether [t] carries no type information a reader can rely on.
bool _untyped(DartType t) => switch (t) {
  DynamicType() => true,
  TypeParameterType(:final bound) => _untyped(bound),
  InterfaceType(:final typeArguments) =>
    t.isDartCoreObject || typeArguments.any(_untyped),
  _ => false,
};

/// `cast-ok:` followed by a reason.
final _castOk = RegExp(r'cast-ok:\s*\S');

class _NoCast extends SimpleAstVisitor<void> {
  _NoCast(this.rule, this.context);
  final AnalysisRule rule;
  final RuleContext context;

  @override
  void visitAsExpression(AsExpression node) {
    final from = node.expression.staticType;
    if (from == null || !_untyped(from)) return;
    if (_hasReason(node.asOperator.offset)) return;
    rule.reportAtNode(node);
  }

  /// Whether the line holding [offset], or the line above it, says
  /// `cast-ok: <why>`.
  bool _hasReason(int offset) {
    final unit = context.currentUnit;
    if (unit == null) return false;
    final lines = unit.unit.lineInfo;
    final line = lines.getLocation(offset).lineNumber - 1;
    for (final n in [line, line - 1]) {
      if (n < 0) continue;
      final start = lines.getOffsetOfLine(n);
      final end = n + 1 < lines.lineCount
          ? lines.getOffsetOfLine(n + 1)
          : unit.content.length;
      if (_castOk.hasMatch(unit.content.substring(start, end))) return true;
    }
    return false;
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
    final v = _NoDefault(this);
    r.addSwitchStatement(this, v);
    r.addSwitchExpression(this, v);
  }
}

class _NoDefault extends SimpleAstVisitor<void> {
  _NoDefault(this.rule);
  final AnalysisRule rule;

  /// The enum or sealed class [t] is, by name; null when it is open.
  String? _closed(DartType? t) => switch (t?.element) {
    final EnumElement e => 'enum ${e.name}',
    final ClassElement c when c.isSealed => 'sealed ${c.name}',
    _ => null,
  };

  bool _isCatchAll(GuardedPattern g) =>
      g.whenClause == null && g.pattern is WildcardPattern;

  @override
  void visitSwitchStatement(SwitchStatement node) {
    final closed = _closed(node.expression.staticType);
    if (closed == null) return;
    for (final m in node.members) {
      if (m is SwitchDefault ||
          (m is SwitchPatternCase && _isCatchAll(m.guardedPattern))) {
        rule.reportAtNode(m, arguments: [closed]);
      }
    }
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    final closed = _closed(node.expression.staticType);
    if (closed == null) return;
    for (final c in node.cases) {
      if (_isCatchAll(c.guardedPattern)) {
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
    : super(name: 'no_ignore_comment', description: 'No // ignore:.');

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
    // Comments hang off the token after them; the ones at the end of the
    // file hang off EOF, which the loop stops at, so it is checked last.
    Token? t = node.beginToken;
    while (true) {
      for (Token? c = t?.precedingComments; c != null; c = c.next) {
        if (_ignore.hasMatch(c.lexeme)) rule.reportAtToken(c);
      }
      if (t == null || t.isEof) break;
      t = t.next;
    }
  }
}
