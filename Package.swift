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
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
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
            cxxSettings: [
                .headerSearchPath("../../../libsword/libsword.xcframework/ios-arm64_x86_64-simulator/Headers/sword"),
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
            path: "Sources/SwordKit/Sources/SwordKit",
            resources: [
                .copy("Resources/compatibility"),
                .copy("Resources/versification"),
                .copy("Resources/tagsoup"),
            ]
        ),
        .testTarget(
            name: "SwordKitTests",
            dependencies: ["SwordKit", "CLibSword"],
            path: "Sources/SwordKit/Tests/SwordKitTests"
        ),

        // Pinned Snowball stemmers matching JSword's Lucene 3.6.2 vocabulary fixtures.
        .target(
            name: "CSearchStemmers",
            path: "Sources/SearchStemmers",
            exclude: ["LICENSE.snowball"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("snowball"),
            ]
        ),

        // BibleCore: Domain models, persistence, business logic
        .target(
            name: "BibleCore",
            dependencies: [
                "SwordKit",
                "CLibSword",
                "CSearchStemmers",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/BibleCore/Sources/BibleCore",
            resources: [
                .copy("Resources/readingplan"),
                .copy("Resources/jsword-bible-names"),
                .copy("Resources/speak"),
                .copy("Resources/search"),
            ]
        ),
        .testTarget(
            name: "BibleCoreTests",
            dependencies: ["BibleCore", "SwordKit", "CLibSword"],
            path: "Sources/BibleCore/Tests/BibleCoreTests",
            exclude: ["Fixtures/android-bookmark-room-v12.sql"],
            resources: [
                .copy("Fixtures/mydocuments"),
                .copy("Fixtures/search"),
            ]
        ),

        // BibleView: WKWebView + Vue.js bridge
        .target(
            name: "BibleView",
            dependencies: ["BibleCore"],
            path: "Sources/BibleView/Sources/BibleView",
            resources: [
                .copy("Resources/index.html"),
                .copy("Resources/bibleview-js"),
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
            dependencies: ["BibleUI", "BibleCore", "BibleView", "SwordKit"],
            path: "Sources/BibleUI/Tests/BibleUITests",
            exclude: ["Fixtures/sword"]
        ),
        .executableTarget(
            name: "UITestFixtureTool",
            dependencies: ["BibleCore", "SwordKit"],
            path: "Tests/Support/UITestFixtureTool"
        ),
    ]
)

// Note: The main iOS app is now in AndBible.xcodeproj
// Use Xcode to open AndBible.xcodeproj, which references this package for library modules
