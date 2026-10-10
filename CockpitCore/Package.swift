// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CockpitCore",
    // English is the source language; each module that words something ships a String
    // Catalog with its French translation.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CockpitShared", targets: ["CockpitShared"]),
        .library(name: "UsageKit", targets: ["UsageKit"]),
        .library(name: "QuotaKit", targets: ["QuotaKit"]),
        .library(name: "RTKKit", targets: ["RTKKit"]),
        .library(name: "SkillsKit", targets: ["SkillsKit"]),
        .library(name: "SessionsKit", targets: ["SessionsKit"]),
        .library(name: "OverviewKit", targets: ["OverviewKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.16.0"),
    ],
    targets: [
        .target(name: "CockpitShared"),
        .target(name: "UsageKit", dependencies: ["CockpitShared"]),
        .target(name: "QuotaKit", dependencies: ["CockpitShared"]),
        .target(name: "RTKKit", dependencies: ["CockpitShared", .product(name: "SQLite", package: "SQLite.swift")]),
        .target(name: "SkillsKit", dependencies: ["CockpitShared"]),
        .target(
            name: "SessionsKit",
            dependencies: ["CockpitShared", .product(name: "SQLite", package: "SQLite.swift")]),
        // Plain values in, ranked kinds out: depends on no other module so every source can
        // feed it, and the app words what it returns.
        .target(name: "OverviewKit"),
        .testTarget(name: "CockpitSharedTests", dependencies: ["CockpitShared"]),
        .testTarget(name: "UsageKitTests", dependencies: ["UsageKit"]),
        .testTarget(name: "QuotaKitTests", dependencies: ["QuotaKit"]),
        .testTarget(name: "RTKKitTests", dependencies: ["RTKKit"]),
        .testTarget(name: "SkillsKitTests", dependencies: ["SkillsKit"]),
        .testTarget(name: "SessionsKitTests", dependencies: ["SessionsKit"]),
        .testTarget(name: "OverviewKitTests", dependencies: ["OverviewKit"]),
    ]
)
