// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
    ],
    dependencies: [
        // No release tags upstream yet; pinned to a known-good commit.
        .package(url: "https://github.com/finnvoor/PiDurableKit.git", revision: "6e7f267181500943db328bbe2a262ae17b39bef1"),
    ],
    targets: [
        .target(name: "AgentCore", dependencies: ["PiDurableKit"]),
        .executableTarget(name: "AgentCLI", dependencies: ["AgentCore"]),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
    ]
)
