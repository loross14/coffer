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
        .target(name: "PlanisphereManaged", dependencies: ["PlanisphereCore"]),
        .executableTarget(name: "PlanisphereApp", dependencies: ["PlanisphereCore"]),
        .testTarget(name: "PlanisphereCoreTests", dependencies: ["PlanisphereCore"]),
        .testTarget(name: "PlanisphereManagedTests", dependencies: ["PlanisphereManaged", "PlanisphereCore"])
    ]
)
