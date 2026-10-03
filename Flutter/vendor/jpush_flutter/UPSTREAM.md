# Vendored JPush Flutter Plugin

- Upstream package: `jpush_flutter`
- Upstream version: `3.4.8`
- Archive SHA-256: `4658a48c9e379e4daaeff1668c5eb12a71e5e9107aa4e8fa30ff34f240bc8450`
- Retrieved from: `https://pub.dev/packages/jpush_flutter`

Pinned iOS native SDK:

- JPush version: `6.2.0`
- JCore version: `5.5.0`
- Official archive SHA-256: `5b2ce4e47447a54eec1f54965c9d1bdd38bcb9e5bd360e1efd556f43bcf6e811`
- Retrieved from: `https://www.jiguang.cn/downloads/sdk/ios`
- Included paths: `ios/jpush_flutter/Frameworks/jpush-ios-6.2.0.xcframework`
  and `ios/jpush_flutter/Frameworks/jcore-ios-5.5.0.xcframework`

The iOS binaries remain copyright Jiguang and are included only for linking the
official Flutter plugin. See `JIGUANG_SDK_NOTICE.md` and the official download
and integration pages for the applicable SDK terms and privacy declarations.

Local patches:

- Remove the two obsolete `jcenter()` repository declarations from
  `android/build.gradle`. Gradle 9 removes that repository helper; Maven Central
  and Google already supply the declared dependencies.
- Add an iOS Swift Package Manager manifest and make the CocoaPods fallback use
  the same pinned local JPush/JCore XCFrameworks. This avoids a build-time
  GitHub clone. The unchanged Objective-C bridge files are moved under the
  Swift package source root and remain shared with CocoaPods; method-channel
  and callback behavior are not changed.
