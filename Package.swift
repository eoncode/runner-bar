// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RunnerBar",
    platforms: [.macOS(.v13)],
    dependencies: [
        // 0.1.5 is the minimum version that introduced skipCodeSignValidation.
        // 1.0.0 does not exist as a tag — do not bump without verifying tags first.
        .package(url: "https://github.com/s1ntoneli/AppUpdater", from: "0.1.5")
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
