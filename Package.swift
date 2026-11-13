// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Aki",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "aki", targets: ["Aki"])],
    // Sparkle (MIT): in-app updates from the appcast on the site, signed with Aki's own key.
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")],
    targets: [
        // Zstandard's decoder (BSD-3-Clause, vendored): the Claude app's cache is zstd.
        .target(name: "CZstd"),
        .target(name: "AkiCore", dependencies: ["CZstd"]),
        .executableTarget(
            name: "Aki", dependencies: ["AkiCore", .product(name: "Sparkle", package: "Sparkle")],
            // Swift 5 mode: the views adapted from Codenotch were written for it.
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // No XCTest/Testing without full Xcode, so checks run as an executable: `swift run AkiChecks`.
        .executableTarget(name: "AkiChecks", dependencies: ["AkiCore"], path: "Tests/AkiChecks"),
    ]
)

#if os(Linux)
// Linux: the core and the command line only. The app (AppKit, Sparkle) is macOS's;
// swift-crypto stands in for CryptoKit.
package.dependencies = [.package(url: "https://github.com/apple/swift-crypto", from: "4.5.2")]
package.targets = [
    .target(name: "CZstd"),
    .target(name: "AkiCore", dependencies: ["CZstd", .product(name: "Crypto", package: "swift-crypto")]),
    .executableTarget(name: "Aki", dependencies: ["AkiCore"], path: "Sources/Aki",
        exclude: ["App", "Codenotch", "History", "Localization", "Marking", "Settings", "Sidebar"],
        swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "AkiChecks", dependencies: ["AkiCore"], path: "Tests/AkiChecks"),
]
#endif
