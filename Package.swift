// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Panescroll",
    platforms: [.macOS(.v14)],
    targets: [
        // The menu bar app. Only starts PanescrollCore.
        .executableTarget(
            name: "Panescroll",
            dependencies: ["PanescrollCore"],
            path: "Sources/Panescroll"
        ),
        // All app logic, split out so it can be unit-tested.
        .target(
            name: "PanescrollCore",
            path: "Sources/PanescrollCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "PanescrollCoreTests",
            dependencies: ["PanescrollCore"],
            path: "Tests/PanescrollCoreTests"
        ),
    ]
)
