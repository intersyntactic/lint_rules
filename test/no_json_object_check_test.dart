/// `no_json_object_check` knows JsonObject by name, whether it is an
/// extension type or a class, so the same code reports the same way against
/// either. Each case runs against a `checked_json` fixture of each shape.
library;

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:is_lint_rules/src/rules.dart';
import 'package:test/test.dart';

/// The two shapes a JsonObject declaration takes.
const _declarations = {
  'extension type': '''
extension type JsonObject._(Map<String, Object?> _map) {
  static JsonObject? parse(Object? value) =>
      value is Map<String, Object?> ? JsonObject._(value) : null;
}
''',
  // checked_json extends UnmodifiableMapBase, which the analyzer's test SDK
  // lacks; MapView makes the same kind of type: a final class that is a Map.
  'class': '''
import 'dart:collection';

final class JsonObject extends MapView<String, Object?> {
  JsonObject._();

  static JsonObject? parse(Object? value) =>
      value is Map<String, Object?> ? JsonObject._() : null;
}

Map<String, Object?> isAMap(JsonObject o) => o;
''',
};

/// A rule test whose package depends on a `checked_json` declaring
/// JsonObject with [declaration].
class _Check extends AnalysisRuleTest {
  _Check(this.declaration);
  final String declaration;

  @override
  void setUp() {
    rule = NoJsonObjectCheck();
    newPackage('checked_json').addFile('lib/checked_json.dart', declaration);
    super.setUp();
  }
}

void main() {
  for (final MapEntry(key: shape, value: declaration)
      in _declarations.entries) {
    group('JsonObject as $shape', () {
      late _Check t;
      setUp(() {
        t = _Check(declaration)..setUp();
      });
      tearDown(() => t.tearDown());

      test('is against JsonObject on a decoded value', () async {
        const code = '''
import 'package:checked_json/checked_json.dart';
bool f(Object? v) => v is JsonObject;
''';
        await t.assertDiagnostics(code, [
          t.lint(code.indexOf('JsonObject;'), 'JsonObject'.length),
        ]);
      });

      test('as against JsonObject', () async {
        const code = '''
import 'package:checked_json/checked_json.dart';
JsonObject f(Object? v) => v as JsonObject;
''';
        await t.assertDiagnostics(code, [
          t.lint(code.lastIndexOf('JsonObject'), 'JsonObject'.length),
        ]);
      });

      test('a pattern typed JsonObject', () async {
        const code = '''
import 'package:checked_json/checked_json.dart';
bool f(Object? v) => switch (v) { final JsonObject _ => true, _ => false };
''';
        await t.assertDiagnostics(code, [
          t.lint(code.lastIndexOf('JsonObject'), 'JsonObject'.length),
        ]);
      });

      test('whereType<JsonObject>', () async {
        const code = '''
import 'package:checked_json/checked_json.dart';
Iterable<JsonObject> f(List<Object?> v) => v.whereType<JsonObject>();
''';
        await t.assertDiagnostics(code, [
          t.lint(code.lastIndexOf('JsonObject'), 'JsonObject'.length),
        ]);
      });

      test('the bare map, where JsonObject can be seen', () async {
        const code = '''
import 'package:checked_json/checked_json.dart';
JsonObject? f(Object? v) => v is Map<String, Object?> ? JsonObject.parse(v) : null;
''';
        await t.assertDiagnostics(code, [
          t.lint(
            code.indexOf('Map<String, Object?>'),
            'Map<String, Object?>'.length,
          ),
        ]);
      });

      test('a test that can fail only on null', () async {
        await t.assertNoDiagnostics('''
import 'package:checked_json/checked_json.dart';
bool f(JsonObject? v) => switch (v) { final JsonObject _ => true, _ => false };
''');
      });

      test('the bare map, where JsonObject cannot be seen', () async {
        await t.assertNoDiagnostics('''
bool f(Object? v) => v is Map<String, Object?>;
''');
      });

      test('the library that declares JsonObject', () async {
        await t.assertNoDiagnostics(
          '$declaration\n'
          'bool f(Object? v) => v is JsonObject;\n',
        );
      });
    });
  }
}
