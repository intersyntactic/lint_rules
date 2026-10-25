/// The rules of AGENTS.md's "Writing Dart" that a plugin can check, or the
/// part of one it can see.
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
  NoStringLiteralCompare(),
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
  final _reasons = _Reasons(_castOk);

  @override
  void visitAsExpression(AsExpression node) {
    final from = node.expression.staticType;
    if (from == null || !_untyped(from)) return;
    if (_reasons.cover(node, node.asOperator.offset)) return;
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
    if (_reasons.cover(node, node.methodName.offset)) return;
    rule.reportAtNode(node);
  }
}

/// The comments matching [marker] (a `cast-ok:` or `wire-ok:` with a reason),
/// and the lines each one covers.
class _Reasons {
  _Reasons(this.marker);
  final RegExp marker;

  /// The lines (0-based) of the unit [_linesOf] that a marker covers, found
  /// once per unit.
  CompilationUnit? _linesOf;
  Set<int> _okLines = const {};

  /// Whether a marker covers the line holding [offset] in [node]'s unit: one
  /// at the end of that line, or one on a line of its own just above it. A
  /// marker after code covers only its own line, so it says nothing about the
  /// code below it. Comments are read as tokens, so the words in a string
  /// literal are not one.
  bool cover(AstNode node, int offset) {
    final unit = node.root;
    if (unit is! CompilationUnit) return false;
    int lineOf(int offset) => unit.lineInfo.getLocation(offset).lineNumber - 1;
    if (!identical(unit, _linesOf)) {
      _linesOf = unit;
      _okLines = {
        for (final (:comment, :before) in _comments(unit))
          if (marker.hasMatch(comment.lexeme)) ...[
            lineOf(comment.offset),
            if (before == null || lineOf(before.end) < lineOf(comment.offset))
              lineOf(comment.offset) + 1,
          ],
      };
    }
    return _okLines.contains(lineOf(offset));
  }
}

/// Every comment in [unit], with the code token [before] it (null at the
/// start of the file). Comments hang off the token after them; the ones at
/// the end of the file hang off EOF, which the walk reaches last.
Iterable<({Token comment, Token? before})> _comments(
  CompilationUnit unit,
) sync* {
  Token? t = unit.beginToken;
  while (true) {
    final previous = t?.previous;
    final before = previous == null || previous.isEof ? null : previous;
    for (Token? c = t?.precedingComments; c != null; c = c.next) {
      yield (comment: c, before: before);
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

/// The analyzer obeys `//+ *ignore:` at the start of a comment, so a doc
/// comment (`/// ignore:`) is one too.
final _ignore = RegExp(r'^//+\s*ignore(_for_file)?\s*:');

class _NoIgnore extends SimpleAstVisitor<void> {
  _NoIgnore(this.rule);
  final AnalysisRule rule;

  @override
  void visitCompilationUnit(CompilationUnit node) {
    for (final (:comment, before: _) in _comments(node)) {
      if (_ignore.hasMatch(comment.lexeme)) rule.reportAtToken(comment);
    }
  }
}

// ---------------------------------------------------------------- strings

/// A string compared with a string literal: `kind == 'mention'`, or a switch
/// whose cases are string literals. The literals are a closed set's values
/// spelled as strings, so the set has no type to switch on exhaustively.
///
/// The value compared may be a `String`, or untyped (`Object?`, `dynamic`):
/// `json['type'] == 'error'` is the same set, read from the wire too late.
///
/// Not reported: inside the members that ARE the wire (`fromJson`, `toJson`,
/// `fromWire`, `toWire`, and any `parse…` or `tryParse…`, closures within them
/// included), against `''` (a test for empty, not a set), or with a
/// `// wire-ok: <why>` on its line or the line above.
class NoStringLiteralCompare extends AnalysisRule {
  static const code = LintCode(
    'no_string_literal_compare',
    "Comparing a string with '{0}': a closed set spelled as strings.",
    correctionMessage:
        'Give the set a type (an enum, a sealed class or an extension type) '
        'and parse it once, in fromJson or a parse. If this is the wire, write '
        '`// wire-ok: <why>` on or above the line.',
  );

  NoStringLiteralCompare()
    : super(
        name: 'no_string_literal_compare',
        description: 'No string compared with a string literal.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry r, RuleContext c) {
    if (c.isInTestDirectory) return;
    final v = _NoStringCompare(this);
    r.addBinaryExpression(this, v);
    r.addSwitchStatement(this, v);
    r.addSwitchExpression(this, v);
  }
}

/// A `// wire-ok:` comment followed by a reason.
final _wireOk = RegExp(r'^//\s*wire-ok:\s*\S');

/// Whether a member named [name] turns wire text into types or back. A
/// leading `_` says who may call it, not what it does: `_parseArgs` is one.
bool _isWireMember(String name) {
  final role = name.replaceFirst(RegExp('^_+'), '');
  return const {'fromJson', 'toJson', 'fromWire', 'toWire'}.contains(role) ||
      role.startsWith('parse') ||
      role.startsWith('tryParse');
}

/// Whether [node] sits inside a wire member, at any depth.
bool _inWireMember(AstNode node) {
  for (AstNode? p = node.parent; p != null; p = p.parent) {
    final name = switch (p) {
      MethodDeclaration(:final name) => name.lexeme,
      FunctionDeclaration(:final name) => name.lexeme,
      ConstructorDeclaration(:final name?) => name.lexeme,
      _ => null,
    };
    if (name != null && _isWireMember(name)) return true;
  }
  return false;
}

/// A type a string-valued set arrives as: `String`, or one that says nothing.
bool _stringOrUntyped(DartType? t) => switch (t) {
  DynamicType() => true,
  InterfaceType() => t.isDartCoreString || t.isDartCoreObject,
  _ => false,
};

/// The value of [e] when it is a string literal other than `''`.
String? _setLiteral(Expression e) => switch (e) {
  StringLiteral(:final stringValue?) when stringValue.isNotEmpty => stringValue,
  ParenthesizedExpression(:final expression) => _setLiteral(expression),
  _ => null,
};

/// The first non-empty string literal a case pattern matches, through `||`.
String? _literalCase(DartPattern p) => switch (p) {
  ConstantPattern(:final expression) => _setLiteral(expression),
  ParenthesizedPattern(:final pattern) => _literalCase(pattern),
  LogicalOrPattern(:final leftOperand, :final rightOperand) =>
    _literalCase(leftOperand) ?? _literalCase(rightOperand),
  // A map or list pattern's literals are keys and elements of the wire
  // shape, which the rule leaves to fromJson; the rest test no string value.
  AssignedVariablePattern() ||
  CastPattern() ||
  DeclaredVariablePattern() ||
  ListPattern() ||
  LogicalAndPattern() ||
  MapPattern() ||
  NullAssertPattern() ||
  NullCheckPattern() ||
  ObjectPattern() ||
  RecordPattern() ||
  RelationalPattern() ||
  WildcardPattern() => null,
};

class _NoStringCompare extends SimpleAstVisitor<void> {
  _NoStringCompare(this.rule);
  final AnalysisRule rule;
  final _reasons = _Reasons(_wireOk);

  void _report(AstNode at, String literal) {
    if (_inWireMember(at) || _reasons.cover(at, at.offset)) return;
    rule.reportAtNode(at, arguments: [literal]);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    final op = node.operator.type;
    if (op != TokenType.EQ_EQ && op != TokenType.BANG_EQ) return;
    final (value, literal) = switch ((
      _setLiteral(node.leftOperand),
      _setLiteral(node.rightOperand),
    )) {
      (final String l, null) => (node.rightOperand, l),
      (null, final String r) => (node.leftOperand, r),
      _ => (null, null),
    };
    if (value == null || literal == null) return;
    if (!_stringOrUntyped(value.staticType)) return;
    _report(node, literal);
  }

  /// One report per switch, at what it switches on: the cases are one set.
  void _switch(Expression on, Iterable<DartPattern> cases) {
    if (!_stringOrUntyped(on.staticType)) return;
    for (final p in cases) {
      if (_literalCase(p) case final literal?) return _report(on, literal);
    }
  }

  @override
  void visitSwitchStatement(SwitchStatement node) => _switch(node.expression, [
    for (final m in node.members)
      if (m is SwitchPatternCase) m.guardedPattern.pattern,
  ]);

  @override
  void visitSwitchExpression(SwitchExpression node) => _switch(
    node.expression,
    [for (final c in node.cases) c.guardedPattern.pattern],
  );
}
