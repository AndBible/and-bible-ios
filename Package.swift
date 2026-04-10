// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AndBible",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SwordKit", targets: ["SwordKit"]),
        .library(name: "BibleCore", targets: ["BibleCore"]),
        .library(name: "BibleView", targets: ["BibleView"]),
        .library(name: "BibleUI", targets: ["BibleUI"]),
        .executable(name: "UITestFixtureTool", targets: ["UITestFixtureTool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/google/GoogleSignIn-iOS", from: "9.0.0"),
    ],
    targets: [
        // Pre-built libsword C++ library (SWORD project)
        .binaryTarget(
            name: "libsword",
            path: "libsword/libsword.xcframework"
        ),

        // C module bridging libsword's flat API via adapter layer
        .target(
            name: "CLibSword",
            dependencies: ["libsword"],
            path: "Sources/SwordKit/CLibSword",
            publicHeadersPath: "include",
            cSettings: [
                .define("USE_REAL_SWORD"),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("curl", .when(platforms: [.macOS])),
                .linkedLibrary("lzma", .when(platforms: [.macOS])),
                .linkedLibrary("c++"),
            ]
        ),

        // SwordKit: Swift wrapper around libsword
        .target(
            name: "SwordKit",
            dependencies: ["CLibSword"],
            path: "Sources/SwordKit/Sources/SwordKit"
        ),
        .testTarget(
            name: "SwordKitTests",
            dependencies: ["SwordKit"],
            path: "Sources/SwordKit/Tests/SwordKitTests"
        ),

        // BibleCore: Domain models, persistence, business logic
        .target(
            name: "BibleCore",
            dependencies: [
                "SwordKit",
                "CLibSword",
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
            ],
            path: "Sources/BibleCore/Sources/BibleCore",
            resources: [
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "BibleCoreTests",
            dependencies: ["BibleCore"],
            path: "Sources/BibleCore/Tests/BibleCoreTests"
        ),

        // BibleView: WKWebView + Vue.js bridge
        .target(
            name: "BibleView",
            dependencies: ["BibleCore"],
            path: "Sources/BibleView/Sources/BibleView",
            resources: [
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "BibleViewTests",
            dependencies: ["BibleView"],
            path: "Sources/BibleView/Tests/BibleViewTests"
        ),

        // BibleUI: SwiftUI feature screens
        .target(
            name: "BibleUI",
            dependencies: ["BibleView", "BibleCore", "SwordKit"],
            path: "Sources/BibleUI/Sources/BibleUI",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "BibleUITests",
            dependencies: ["BibleUI"],
            path: "Sources/BibleUI/Tests/BibleUITests"
        ),
        .executableTarget(
            name: "UITestFixtureTool",
            dependencies: ["BibleCore"],
            path: "Tools/UITestFixtureTool"
        ),
    ]
)

// Note: The main iOS app is now in AndBible.xcodeproj
// Use Xcode to open AndBible.xcodeproj, which references this package for library modules
