import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:lint_rules/src/rules.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(NoDynamicTest);
    defineReflectiveTests(NoCastFromUntypedTest);
    defineReflectiveTests(NoDefaultOnClosedTypeTest);
    defineReflectiveTests(NoIgnoreCommentTest);
  });
}

/// A rule's test, with lints placed by the text they cover rather than by
/// counted offsets.
abstract class _RuleTest extends AnalysisRuleTest {
  AbstractAnalysisRule get underTest;

  @override
  void setUp() {
    rule = underTest;
    super.setUp();
  }

  /// [source] reports exactly one lint on each of [texts], found in order.
  Future<void> lintsOn(String source, List<String> texts) {
    final offsets = <int>[];
    var from = 0;
    for (final t in texts) {
      from = source.indexOf(t, from);
      offsets.add(from);
      from += t.length;
    }
    return assertDiagnostics(source, [
      for (var i = 0; i < texts.length; i++) lint(offsets[i], texts[i].length),
    ]);
  }

  /// [source] reports nothing when it is in the package's `test/`, though
  /// the same code in `lib/` does.
  Future<void> silentInTestDir(String source) async {
    final path = '$testPackageTestPath/a_test.dart';
    newFile(path, source);
    await assertNoDiagnosticsInFile(path);
  }
}

@reflectiveTest
class NoDynamicTest extends _RuleTest {
  @override
  AbstractAnalysisRule get underTest => NoDynamic();

  static const _both = 'dynamic f(dynamic x) => x;\n';

  Future<void> test_written_dynamic() => lintsOn(_both, ['dynamic', 'dynamic']);

  Future<void> test_object_is_fine() =>
      assertNoDiagnostics('Object? f(Object? x) => x;\n');

  Future<void> test_not_in_test_dir() => silentInTestDir(_both);
}

@reflectiveTest
class NoCastFromUntypedTest extends _RuleTest {
  @override
  AbstractAnalysisRule get underTest => NoCastFromUntyped();

  Future<void> test_object() =>
      lintsOn('String f(Object? o) => o as String;\n', ['o as String']);

  Future<void> test_dynamic() =>
      lintsOn('int f(dynamic d) => d as int;\n', ['d as int']);

  Future<void> test_unbounded_type_parameter() =>
      lintsOn('String f<T>(T t) => t as String;\n', ['t as String']);

  Future<void> test_to_a_type_parameter() =>
      lintsOn('T f<T>(Object? o) => o as T;\n', ['o as T']);

  Future<void> test_generic_of_object() => lintsOn(
    'List<String> f(List<Object?> l) => l as List<String>;\n',
    ['l as List<String>'],
  );

  Future<void> test_typed_downcasts_are_fine() => assertNoDiagnostics('''
int f(num n) => n as int;
List<int> g(Iterable<int> i) => i as List<int>;
String h<T extends String?>(T t) => t as String;
''');

  Future<void> test_reason_on_the_line() => assertNoDiagnostics(
    'String f(Object? o) => o as String; // cast-ok: the SDK types it so\n',
  );

  Future<void> test_reason_on_the_line_above() => assertNoDiagnostics('''
// cast-ok: the SDK types it so
String f(Object? o) => o as String;
''');

  Future<void> test_a_marker_needs_a_reason() => lintsOn(
    'String f(Object? o) => o as String; // cast-ok:\n',
    ['o as String'],
  );

  Future<void> test_a_reason_two_lines_up_is_not_next_to_it() => lintsOn(
    '''
// cast-ok: about something else
void g() {}
String f(Object? o) => o as String;
''',
    ['o as String'],
  );

  Future<void> test_a_reason_in_a_string_is_not_a_comment() => lintsOn(
    "String f(Object? o) => [o as String, 'cast-ok: in a string'].first;\n",
    ['o as String'],
  );

  // T extends Comparable<T> leads back to T: the walk over bounds must end.
  Future<void> test_a_recursive_bound_is_typed() => assertNoDiagnostics(
    'int f<T extends Comparable<T>>(T a, Comparable<T> b) =>\n'
    '    (b as T).compareTo(a);\n',
  );

  Future<void> test_not_in_test_dir() =>
      silentInTestDir('String f(Object? o) => o as String;\n');
}

@reflectiveTest
class NoDefaultOnClosedTypeTest extends _RuleTest {
  @override
  AbstractAnalysisRule get underTest => NoDefaultOnClosedType();

  static const _enumStatement = '''
enum E { a, b }
int f(E e) {
  switch (e) {
    case E.a:
      return 1;
    default:
      return 2;
  }
}
''';

  Future<void> test_default_on_an_enum() =>
      lintsOn(_enumStatement, ['default:\n      return 2;']);

  Future<void> test_wildcard_on_an_enum() => lintsOn(
    '''
enum E { a, b }
int f(E e) => switch (e) { E.a => 1, _ => 2 };
''',
    ['_ => 2'],
  );

  Future<void> test_wildcard_on_a_sealed_class() => lintsOn(
    '''
sealed class S {}
final class A extends S {}
final class B extends S {}
int f(S s) => switch (s) { A() => 1, _ => 2 };
''',
    ['_ => 2'],
  );

  Future<void> test_a_guarded_wildcard_is_fine() => assertNoDiagnostics('''
enum E { a, b }
int f(E e, bool c) => switch (e) { _ when c => 0, E.a => 1, E.b => 2 };
''');

  Future<void> test_a_bare_variable_is_a_catch_all() => lintsOn(
    '''
enum E { a, b }
int f(E e) => switch (e) { E.a => 1, final other => 2 };
''',
    ['final other => 2'],
  );

  Future<void> test_the_type_itself_is_a_catch_all() => lintsOn(
    '''
sealed class S {}
final class A extends S {}
final class B extends S {}
int f(S s) => switch (s) { A() => 1, S() => 2 };
''',
    ['S() => 2'],
  );

  Future<void> test_a_subtype_is_not_a_catch_all() => assertNoDiagnostics('''
sealed class S {}
final class A extends S {}
final class B extends S {}
int f(S s) => switch (s) { A() => 1, B() => 2 };
''');

  Future<void> test_a_wildcard_on_an_open_type_is_fine() => assertNoDiagnostics(
    'int? f(Object? o) => switch (o) { final int i => i, _ => null };\n',
  );

  Future<void> test_not_in_test_dir() => silentInTestDir(_enumStatement);
}

@reflectiveTest
class NoIgnoreCommentTest extends _RuleTest {
  @override
  AbstractAnalysisRule get underTest => NoIgnoreComment();

  static const _middle = '''
// ignore: lint_rules/no_dynamic
void f() {}
''';

  Future<void> test_ignore_before_code() =>
      lintsOn(_middle, ['// ignore: lint_rules/no_dynamic']);

  Future<void> test_ignore_for_file_at_the_end() => lintsOn(
    '''
void f() {}
// ignore_for_file: lint_rules/no_dynamic
''',
    ['// ignore_for_file: lint_rules/no_dynamic'],
  );

  Future<void> test_other_comments_are_fine() => assertNoDiagnostics('''
// Do not ignore: this is prose.
/// ignore: a doc comment is not a suppression
void f() {}
''');

  Future<void> test_not_in_test_dir() => silentInTestDir(_middle);
}
