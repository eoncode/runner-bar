// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RunnerBar",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/s1ntoneli/AppUpdater",
            .upToNextMajor(from: "2.0.0")
        )
    ],
    targets: [
        .executableTarget(
            name: "RunnerBar",
            dependencies: [
                .product(name: "AppUpdater", package: "AppUpdater")
            ],
            path: "Sources/RunnerBar"
        )
    ]
)
