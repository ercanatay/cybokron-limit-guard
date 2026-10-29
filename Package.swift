// swift-tools-version:6.0
//
// SwiftPM manifest for building and testing without Xcode (Command Line Tools only).
// The Xcode project (CybokronLimitGuard.xcodeproj, generated from project.yml) builds the same
// sources; use scripts/build-app.sh to wrap the SwiftPM binary into an .app bundle.
import PackageDescription

let package = Package(
    name: "CybokronLimitGuard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CybokronLimitGuard", targets: ["CybokronLimitGuard"]),
        .library(name: "LimitGuardCore", targets: ["LimitGuardCore"]),
    ],
    targets: [
        .target(
            name: "LimitGuardCore",
            path: "Sources/LimitGuardCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CybokronLimitGuard",
            dependencies: ["LimitGuardCore"],
            path: "Sources/CybokronLimitGuard"
        ),
        .testTarget(
            name: "LimitGuardCoreTests",
            dependencies: ["LimitGuardCore"],
            path: "Tests/LimitGuardCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
