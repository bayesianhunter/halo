// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

let package = Package(
    name: "Halo",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Halo", targets: ["Halo"])],
    // The only third-party dependency: updates for copies installed outside Homebrew. Pinned, since it downloads and
    // runs code; move it on purpose.
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "HaloHID", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "HaloCore"),
        // Sparkle is linked into the app alone; HaloCore and HaloHID never reach the network through it.
        // The binary loads @rpath/Sparkle.framework and SwiftPM adds only @loader_path (Contents/MacOS); the bundle
        // keeps the framework in Contents/Frameworks, where codesign expects it (scripts/build-app.sh copies it).
        .executableTarget(name: "Halo", dependencies: ["HaloHID", "HaloCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "HaloTests", dependencies: ["HaloCore", "HaloHID"])
    ],
    swiftLanguageModes: [.v5]
)
