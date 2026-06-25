// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "RunnerBar",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "RunnerBarCore",
            targets: ["RunnerBarCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0")
    ],
    targets: [
        .target(
            name: "RunnerBarCore",
            dependencies: [
                .product(name: "Collections", package: "swift-collections")
            ],
            path: "Sources/RunnerBarCore",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .executableTarget(
            name: "RunnerBar",
            dependencies: ["RunnerBarCore"],
            path: "Sources/RunnerBar",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "RunnerBarCoreTests",
            dependencies: [
                "RunnerBarCore",
                .product(name: "Collections", package: "swift-collections")
            ],
            path: "Tests/RunnerBarCoreTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ]
)
