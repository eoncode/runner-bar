// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RunnerBar",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Pinned exact: prevents silent 0.2.x resolution that could break
        // skipCodeSignValidation or rename state enum cases.
        // Before bumping: check release notes at
        // https://github.com/s1ntoneli/AppUpdater/releases
        .package(url: "https://github.com/s1ntoneli/AppUpdater", exact: "0.1.9")
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
