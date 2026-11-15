// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Reel",
    platforms: [.macOS(.v14)],
    targets: [
        // The menu bar app. Only starts ReelCore.
        .executableTarget(
            name: "Reel",
            dependencies: ["ReelCore"],
            path: "Sources/Reel"
        ),
        // All app logic, split out so it can be unit-tested.
        .target(
            name: "ReelCore",
            path: "Sources/ReelCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "ReelCoreTests",
            dependencies: ["ReelCore"],
            path: "Tests/ReelCoreTests"
        ),
    ]
)
