// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentPulse",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentPulse", targets: ["AgentPulse"]),
        .library(name: "AgentPulseCore", targets: ["AgentPulseCore"]),
    ],
    targets: [
        .target(
            name: "AgentPulseCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AgentPulse",
            dependencies: ["AgentPulseCore"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "AgentPulseTests",
            dependencies: ["AgentPulseCore"]
        ),
    ]
)
