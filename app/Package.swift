// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HorizonXILauncher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "HorizonXILauncher",
            path: "Sources/HorizonXILauncher"
        ),
        .testTarget(
            name: "HorizonXILauncherTests",
            dependencies: ["HorizonXILauncher"],
            path: "Tests/HorizonXILauncherTests"
        ),
    ]
)
