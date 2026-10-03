// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "jpush_flutter",
    platforms: [
        .iOS("13.0"),
    ],
    products: [
        .library(name: "jpush-flutter", targets: ["jpush_flutter"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .binaryTarget(
            name: "JCore",
            path: "Frameworks/jcore-ios-5.5.0.xcframework"
        ),
        .binaryTarget(
            name: "JPush",
            path: "Frameworks/jpush-ios-6.2.0.xcframework"
        ),
        .target(
            name: "jpush_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                "JCore",
                "JPush",
            ],
            path: "Sources/jpush_flutter",
            publicHeadersPath: ".",
            linkerSettings: [
                .linkedFramework("UIKit"),
                .linkedFramework("CFNetwork"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreTelephony"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation"),
                .linkedFramework("Security"),
                .linkedFramework("WebKit"),
                .linkedFramework("UserNotifications"),
                .linkedLibrary("z"),
                .linkedLibrary("resolv"),
                .unsafeFlags(["-weak_framework", "AppTrackingTransparency"]),
            ]
        ),
    ]
)
