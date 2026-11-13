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
// `aki mark`'s overlay (GTK 4 on X11), its own executable: `aki` stays without GTK and
// runs where libgtk-4-1 isn't installed; `aki mark` execs the `aki-mark` beside it.
package.products.append(.executable(name: "aki-mark", targets: ["AkiLinux"]))
package.targets.append(contentsOf: [
    .systemLibrary(name: "CGtk", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"])]),
    .systemLibrary(name: "CX11", pkgConfig: "x11", providers: [.apt(["libx11-dev"])]),
    // Swift 5 mode: GTK's C callbacks run on the GLib loop's thread, which Swift 6 can't see as the main actor.
    .executableTarget(name: "AkiLinux", dependencies: ["AkiCore", "CGtk", "CX11"],
        swiftSettings: [.swiftLanguageMode(.v5)]),
])
#endif
