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
        .executableTarget(name: "JevLauncher", dependencies: ["LauncherCore"]),
        .executableTarget(name: "JevRunner", dependencies: ["LauncherCore"]),
        .testTarget(name: "LauncherCoreTests", dependencies: ["LauncherCore"]),
        .testTarget(name: "JevLauncherTests", dependencies: ["JevLauncher"])
    ],
    swiftLanguageModes: [.v5]
)
