// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RunnerBar",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/s1ntoneli/AppUpdater",
            exact: "0.1.9"
            // Pinned exact: prevents silent resolution that could break
            // skipCodeSignValidation or rename state enum cases.
            // Before bumping: check https://github.com/s1ntoneli/AppUpdater/releases
        )
    ],
    targets: [
        .executableTarget(
            name: "RunnerBar",
            dependencies: ["AppUpdater"],
            path: "Sources/RunnerBar"
        )
    ]
)
