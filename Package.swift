// swift-tools-version: 6.0
// Plane World — native macOS flight/vehicle physics sandbox.
// Build: swift build --scratch-path <scratch>   Run: swift run PlaneWorld [--selftest <name|all>]
import PackageDescription

// Swift 6 compiler; modules use Swift 5 language mode so that the job system's
// shared-memory parallelism (unsafe buffer access from worker threads) does not
// fight strict-concurrency checking. Thread-safety is documented in docs/ARCHITECTURE.md.
let common: [SwiftSetting] = [
    .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
]

let package = Package(
    name: "PlaneWorld",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "PlaneWorld", targets: ["PlaneWorld"]),
    ],
    targets: [
        .target(name: "PWCore", path: "Sources/Core", swiftSettings: common),
        .target(name: "PWRender", dependencies: ["PWCore"], path: "Sources/Render", swiftSettings: common),
        .target(name: "PWCollision", dependencies: ["PWCore"], path: "Sources/Collision", swiftSettings: common),
        .target(name: "PWPhysics", dependencies: ["PWCore", "PWCollision"], path: "Sources/Physics", swiftSettings: common),
        .target(name: "PWTerrain", dependencies: ["PWCore", "PWRender"], path: "Sources/Terrain", swiftSettings: common),
        .target(name: "PWVegetation", dependencies: ["PWCore", "PWRender"], path: "Sources/Vegetation", swiftSettings: common),
        .target(name: "PWWater", dependencies: ["PWCore", "PWRender"], path: "Sources/Water", swiftSettings: common),
        // Full-flow CFD (GPU lattice-Boltzmann) behind PWCore.AeroBackend; see docs/FIDELITY.md.
        .target(name: "PWFlow", dependencies: ["PWCore"], path: "Sources/Flow", swiftSettings: common, linkerSettings: [.linkedFramework("Metal")]),
        .target(name: "PWCraft", dependencies: ["PWCore", "PWRender", "PWPhysics"], path: "Sources/Craft", swiftSettings: common),
        // Evolution workbench (EVOLVE tab): headless world, evaluators, algorithms, JavaScriptCore scripting.
        .target(name: "PWEvolution", dependencies: ["PWCore", "PWPhysics", "PWCollision", "PWTerrain", "PWWater", "PWVegetation", "PWFlow", "PWCraft"], path: "Sources/Evolution",
                swiftSettings: common, linkerSettings: [.linkedFramework("JavaScriptCore")]),
        .executableTarget(
            name: "PlaneWorld",
            dependencies: ["PWCore", "PWRender", "PWPhysics", "PWCollision", "PWTerrain", "PWVegetation", "PWWater", "PWCraft", "PWEvolution", "PWFlow"],
            path: "Sources/App",
            resources: [.copy("Resources/Crafts")],
            swiftSettings: common),
        .testTarget(name: "CoreTests", dependencies: ["PWCore"], path: "Tests/CoreTests", swiftSettings: common),
    ],
    swiftLanguageModes: [.v5]
)
