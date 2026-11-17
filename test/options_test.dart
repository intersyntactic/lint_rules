/// The analyzer says nothing about a rule name it does not know under
/// `plugins: is_lint_rules: diagnostics:`: a misspelled `no_dynamc: true`
/// turns nothing on and analysis still says "No issues found". So the
/// README's options, which people copy, must name exactly the rules the
/// plugin registers.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:is_lint_rules/src/rules.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// This package's directory, found from its own library rather than from
/// where the test was started.
final _package = File.fromUri(
  Isolate.resolvePackageUriSync(Uri.parse('package:is_lint_rules/main.dart'))!,
).parent.parent;

/// The fenced YAML blocks of a Markdown file.
final _yamlBlock = RegExp(
  r'^```yaml\n(.*?)^```',
  multiLine: true,
  dotAll: true,
);

void main() {
  test('the README names every rule, and only those', () {
    final readme = File(_package.uri.resolve('README.md').toFilePath());
    final blocks = [
      for (final m in _yamlBlock.allMatches(readme.readAsStringSync()))
        m.group(1)!,
    ];
    expect(blocks, hasLength(1), reason: 'one options block to copy');
    final diagnostics = switch (loadYaml(blocks.single)) {
      {
        'plugins': {
          'is_lint_rules': {'diagnostics': final Map<Object?, Object?> d},
        },
      } =>
        d,
      _ => fail('README has no plugins: is_lint_rules: diagnostics: section'),
    };
    expect(diagnostics.keys.toSet(), {for (final r in rules) r.name});
    for (final MapEntry(:key, :value) in diagnostics.entries) {
      expect(value, isA<bool>(), reason: '$key: $value');
    }
  });
}
