// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Aki",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "aki", targets: ["Aki"])],
    // Sparkle (MIT): in-app updates from the appcast on the site, signed with Aki's own key.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "4.5.2"),
    ],
    targets: [
        // Zstandard's decoder (BSD-3-Clause, vendored): the Claude app's cache is zstd.
        .target(name: "CZstd"),
        .target(name: "AkiCore", dependencies: ["CZstd",
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))]),
        .executableTarget(
            name: "Aki", dependencies: ["AkiCore", .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))],
            // Swift 5 mode: the views adapted from Codenotch were written for it.
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // No XCTest/Testing without full Xcode, so checks run as an executable: `swift run AkiChecks`.
        .executableTarget(name: "AkiChecks", dependencies: ["AkiCore"], path: "Tests/AkiChecks"),
    ]
)

#if os(Linux)
// The Linux executable contains only the CLI; the app uses macOS frameworks.
package.targets.first { $0.name == "Aki" }?.exclude = [
    "App", "Codenotch", "History", "Localization", "Marking", "Settings", "Sidebar",
]
#endif
