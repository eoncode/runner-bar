// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RunnerBar",
    platforms: [.macOS(.v13)],
    targets: [
        // Thin executable — only main.swift lives here
        .executableTarget(
            name: "RunnerBar",
            dependencies: ["RunnerBarCore"],
            path: "Sources/RunnerBar",
            sources: ["main.swift"]
        ),
        // All business logic — testable via swift test
        .target(
            name: "RunnerBarCore",
            path: "Sources/RunnerBarCore"
        ),
        .testTarget(
            name: "RunnerBarTests",
            dependencies: ["RunnerBarCore"],
            path: "Tests/RunnerBarTests"
        )
    ]
)
