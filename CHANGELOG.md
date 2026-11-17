## 0.1.1

- The README says where `plugins:` goes (the top level, not under
  `analyzer:`, where the rules never run) and gives a probe that shows the
  plugin ran.

## 0.1.0

- First release: seven rules, each off until an `analysis_options.yaml`
  turns it on under `plugins: is_lint_rules: diagnostics:`.
  `no_dynamic`, `no_cast_from_untyped`, `no_default_on_closed_type`,
  `no_ignore_comment`, `no_json_object_check`, `no_string_literal_compare`
  and `no_visible_for_testing`. None reports in a test directory.
