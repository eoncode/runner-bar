// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RunnerBar",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "RunnerBarCore",
            path: "Sources/RunnerBarCore"
        ),
        .executableTarget(
            name: "RunnerBar",
            dependencies: ["RunnerBarCore"],
            path: "Sources/RunnerBar"
        ),
        .testTarget(
            name: "RunnerBarCoreTests",
            dependencies: ["RunnerBarCore"],
            path: "Tests/RunnerBarCoreTests"
        )
    ]
)
