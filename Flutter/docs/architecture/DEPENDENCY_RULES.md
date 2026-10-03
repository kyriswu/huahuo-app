# Flutter dependency rules

The allowed direction inside a feature is:

```text
presentation -> application -> domain
data ---------> application/domain ports
```

`domain` never imports application, data, presentation, or app bootstrap.
`shared` never imports app or feature code. A feature never imports another
feature's presentation layer. Mobile and desktop application roots remain
independent; genuinely shared code belongs in an existing package only after a
second consumer exists.

New presentation code must consume an application/domain port instead of a
concrete data implementation. Existing exceptions are recorded as
non-increasing extraction debt by the architecture check.

Run from `Flutter/src`:

```sh
dart run tool/source_reachability_check.dart
```
