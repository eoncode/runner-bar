// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RunnerBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RunnerBar",
            path: "Sources/RunnerBar"
        )
    ]
)
