// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "JevLauncher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JevLauncher", targets: ["JevLauncher"]),
        .executable(name: "jevcast-runner", targets: ["JevRunner"])
    ],
    targets: [
        .target(name: "LauncherCore"),
        // libghostty for the Terminal window. scripts/ghosttykit.sh builds it from pinned Ghostty source.
        .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),
        .executableTarget(name: "JevLauncher", dependencies: ["LauncherCore", "GhosttyKit"],
                          linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Carbon"), .linkedFramework("Metal"),
                                           .linkedFramework("QuartzCore"), .linkedFramework("IOSurface")]),
        .executableTarget(name: "JevRunner", dependencies: ["LauncherCore"]),
        .testTarget(name: "LauncherCoreTests", dependencies: ["LauncherCore"]),
        .testTarget(name: "JevLauncherTests", dependencies: ["JevLauncher"])
    ],
    swiftLanguageModes: [.v5]
)
