// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Planisphere",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PlanisphereCore", targets: ["PlanisphereCore"]),
        .library(name: "PlanisphereManaged", targets: ["PlanisphereManaged"]),
        .executable(name: "Planisphere", targets: ["PlanisphereApp"]),
        .executable(name: "planisphere-memory", targets: ["MemoryCLI"])
    ],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
    targets: [
        .binaryTarget(name: "Sparkle",
                      url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip",
                      checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "PlanisphereMemory", dependencies: ["CSQLite"]),
        .executableTarget(name: "MemoryCLI", dependencies: ["PlanisphereMemory"]),
        .testTarget(name: "PlanisphereMemoryTests", dependencies: ["PlanisphereMemory"]),
        .target(name: "PlanisphereCore"),
        .target(name: "PlanisphereGrapheine"),
        .target(name: "PlanisphereGraph"),
        .target(name: "PlanisphereConnection"),
        .target(name: "PlanisphereManaged", dependencies: ["PlanisphereCore"]),
        .executableTarget(name: "PlanisphereApp", dependencies: ["PlanisphereCore", "PlanisphereGrapheine", "PlanisphereGraph", "PlanisphereConnection", "PlanisphereMemory", "Sparkle", .product(name: "SwiftTerm", package: "SwiftTerm")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "PlanisphereConnectionTests", dependencies: ["PlanisphereConnection"]),
        .testTarget(name: "PlanisphereAppTests", dependencies: ["PlanisphereApp", "PlanisphereConnection"]),
        .testTarget(name: "PlanisphereGraphTests", dependencies: ["PlanisphereGraph"]),
        .testTarget(name: "PlanisphereGrapheineTests", dependencies: ["PlanisphereGrapheine"]),
        .testTarget(name: "PlanisphereCoreTests", dependencies: ["PlanisphereCore"]),
        .testTarget(name: "PlanisphereManagedTests", dependencies: ["PlanisphereManaged", "PlanisphereCore"])
    ]
)
