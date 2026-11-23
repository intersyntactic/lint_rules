## 0.1.3

- `no_string_literal_compare` advises an enum, or a sealed class when the
  cases carry data. It no longer suggests an extension type, which any
  `String` can be cast to without the parse.

## 0.1.2

- Built on analyzer 14.7.0 and analysis_server_plugin 0.3.26, still pinned
  exactly.

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
