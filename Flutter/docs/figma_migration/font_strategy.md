# Flutter font strategy for Mobile V5

- Chinese production UI remains `PingFang SC` first on iOS, matching the
  platform screenshots and existing theme metrics.
- The complete `NotoSansSC-Variable.ttf` is the first bundled Chinese fallback
  and is registered in `pubspec.yaml`; it is used when PingFang is unavailable,
  including Android, desktop widget tests and golden generation.
- Latin glyphs continue through `Helvetica Neue`, Noto and Roboto fallbacks.
- Mobile V5 implementation uses explicit logical sizes and normal/medium
  weights from each accepted Figma node. It does not copy Figma font metadata
  blindly or introduce extra-bold weights.
- The compact Noto Regular subset remains the PDF export font. Both bundled
  files use the adjacent OFL license.

This resolves the Figma Noto versus iOS PingFang/SF typography mismatch without
requiring platform checks in individual widgets.
