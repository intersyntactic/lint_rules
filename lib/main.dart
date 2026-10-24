import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'src/rules.dart';

/// The analysis server looks for this top-level `plugin`.
final plugin = LintRulesPlugin();

/// Every rule is a lint rule, so it is off until an `analysis_options.yaml`
/// turns it on under `plugins: lint_rules: diagnostics:`.
class LintRulesPlugin extends Plugin {
  @override
  String get name => 'lint_rules';

  @override
  void register(PluginRegistry registry) =>
      rules.forEach(registry.registerLintRule);
}
