# is_lint_rules

An analyzer plugin for stricter Dart. Each rule closes a gap where a value
loses its type and the compiler stops checking it: a written `dynamic`, an
`as` on a value with no type to trust, a `default` that swallows the next case
of an enum, an `// ignore:` that silences the analyzer.

## Using it

Add it under `plugins:` in `analysis_options.yaml`. You don't add it to
`pubspec.yaml`: the analysis server resolves a plugin in a package of its own,
so its `analyzer` pin never enters your solve.

Every rule is a lint, off until you turn it on, so name each one under
`diagnostics:`:

```yaml
plugins:
  is_lint_rules:
    version: ^0.1.0
    diagnostics:
      no_dynamic: true
      no_cast_from_untyped: true
      no_default_on_closed_type: true
      no_ignore_comment: true
      no_json_object_check: true
      no_string_literal_compare: true
      no_visible_for_testing: true
```

The analyzer says nothing about a rule name it does not know, so a misspelled
`no_dynamc: true` turns nothing on and analysis still says "No issues found".
Copy the names from here.

Restart the analysis server after changing the plugin's entry. `dart analyze`
reports the rules too.

No rule reports in a package's test directories (`test/`, `integration_test/`,
`test_driver/`): a test builds bad input on purpose, and casting a fixture is
how it says what it expects.

## The rules

### `no_dynamic`

Any `dynamic` written out. JSON arrives as `Object?`; narrow it with a pattern.

### `no_cast_from_untyped`

`as` or `.cast<R>()` on a value with no type to trust: `dynamic`, `Object` or
`Object?`, a generic of them (`Map<String, Object?>`), or a type parameter
bounded by one. Use a pattern (`case final String s`), which falls through
instead of throwing. When a cast really is right, say why on the line or the
line above:

```dart
// cast-ok: the isolate only ever sends a Request
final request = message as Request;
```

### `no_default_on_closed_type`

`default` or `_` in a switch on an enum or a sealed class, including one
reached through a type parameter. Naming every case makes the next one added
fail to compile until the switch handles it.

### `no_ignore_comment`

Any `// ignore:` or `// ignore_for_file:`, including
`// ignore: is_lint_rules/<rule>`, which would silence these rules. Doc
comments count: the analyzer obeys `/// ignore:` too.

### `no_json_object_check`

For code that reads JSON through an extension type named `JsonObject`: an
`as`, `is`, typed pattern, `whereType` or `cast` against `JsonObject` or the
`Map<String, Object?>` it wraps, outside the library that declares it. At
runtime a test against an extension type tests the map inside, so it repeats
the check `JsonObject`'s constructors already made. Reported only in a library
that can see a `JsonObject` through its package's imports; elsewhere a
string-keyed map is all there is.

### `no_string_literal_compare`

A string compared with a string literal (`kind == 'mention'`), or a switch
whose cases are string literals. The literals are a closed set spelled as
strings; give the set a type (an enum, a sealed class or an extension type) and
parse it once. Not reported inside the members that are the wire (`fromJson`,
`toJson`, `fromWire`, `toWire`, and any `parse…` or `tryParse…`), against `''`,
or with a reason:

```dart
// wire-ok: the protocol's own handshake token
if (line == 'HELLO') return;
```

### `no_visible_for_testing`

`@visibleForTesting` from `package:meta`. The analyzer reports only a call to
such a member from outside the tests, never the annotation, so a member opened
for a test alone goes unnoticed. Pass the class what it depends on instead,
with the real one as the default, so the test drives the path the app runs.
