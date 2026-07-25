// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BMR1Guard",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "GuardCore",
            path: "Sources/GuardCore"
        ),
        .executableTarget(
            name: "BMR1Guard",
            dependencies: ["GuardCore"],
            path: "Sources/BMR1Guard"
        ),
        .testTarget(
            name: "GuardCoreTests",
            dependencies: ["GuardCore"],
            path: "Tests/GuardCoreTests"
        ),
    ]
)
