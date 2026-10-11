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
        .binaryTarget(name: "Sparkle",
                      url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip",
                      checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"),
        .target(name: "PlanisphereCore"),
        .target(name: "PlanisphereGrapheine"),
        .target(name: "PlanisphereGraph"),
        .target(name: "PlanisphereConnection"),
        .target(name: "PlanisphereManaged", dependencies: ["PlanisphereCore"]),
        .executableTarget(name: "PlanisphereApp", dependencies: ["PlanisphereCore", "PlanisphereGrapheine", "PlanisphereGraph", "PlanisphereConnection", "Sparkle"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "PlanisphereConnectionTests", dependencies: ["PlanisphereConnection"]),
        .testTarget(name: "PlanisphereGraphTests", dependencies: ["PlanisphereGraph"]),
        .testTarget(name: "PlanisphereGrapheineTests", dependencies: ["PlanisphereGrapheine"]),
        .testTarget(name: "PlanisphereCoreTests", dependencies: ["PlanisphereCore"]),
        .testTarget(name: "PlanisphereManagedTests", dependencies: ["PlanisphereManaged", "PlanisphereCore"])
    ]
)
