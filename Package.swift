// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Planisphere",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PlanisphereCore", targets: ["PlanisphereCore"]),
        .library(name: "PlanisphereManaged", targets: ["PlanisphereManaged"]),
        .executable(name: "Planisphere", targets: ["PlanisphereApp"])
    ],
    targets: [
        .target(name: "PlanisphereCore"),
        .target(name: "PlanisphereGrapheine"),
        .target(name: "PlanisphereGraph"),
        .target(name: "PlanisphereConnection"),
        .target(name: "PlanisphereManaged", dependencies: ["PlanisphereCore"]),
        .executableTarget(name: "PlanisphereApp", dependencies: ["PlanisphereCore", "PlanisphereGrapheine", "PlanisphereGraph", "PlanisphereConnection"]),
        .testTarget(name: "PlanisphereConnectionTests", dependencies: ["PlanisphereConnection"]),
        .testTarget(name: "PlanisphereGraphTests", dependencies: ["PlanisphereGraph"]),
        .testTarget(name: "PlanisphereGrapheineTests", dependencies: ["PlanisphereGrapheine"]),
        .testTarget(name: "PlanisphereCoreTests", dependencies: ["PlanisphereCore"]),
        .testTarget(name: "PlanisphereManagedTests", dependencies: ["PlanisphereManaged", "PlanisphereCore"])
    ]
)
