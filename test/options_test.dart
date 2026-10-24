/// The analyzer says nothing about a rule name it does not know under
/// `plugins: lint_rules: diagnostics:`: a misspelled `no_dynamc: true` turns
/// nothing on and analysis still says "No issues found". So every options
/// file that enables the plugin must name exactly the rules it registers,
/// each one on or off.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:lint_rules/src/rules.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The options files that enable the plugin, from this package's directory.
const _optionsFiles = [
  '../../analysis_options.yaml',
  '../intersyntactic_app/analysis_options.yaml',
];

/// This package's directory, found from its own library rather than from
/// where the test was started.
final _package = File.fromUri(
  Isolate.resolvePackageUriSync(Uri.parse('package:lint_rules/main.dart'))!,
).parent.parent;

void main() {
  final registered = {for (final r in rules) r.name};

  for (final path in _optionsFiles) {
    test('$path names every rule, and only those', () {
      final file = File(_package.uri.resolve(path).toFilePath());
      final diagnostics = switch (loadYaml(file.readAsStringSync())) {
        {
          'plugins': {
            'lint_rules': {'diagnostics': final Map<Object?, Object?> d},
          },
        } =>
          d,
        _ => fail('$path has no plugins: lint_rules: diagnostics: section'),
      };
      expect(diagnostics.keys.toSet(), registered);
      for (final MapEntry(:key, :value) in diagnostics.entries) {
        expect(value, isA<bool>(), reason: '$key: $value');
      }
    });
  }
}
