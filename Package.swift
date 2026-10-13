// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EFM",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EFMCore", targets: ["EFMCore"]),
        .executable(name: "efm", targets: ["efm"]),
        .executable(name: "EFMApp", targets: ["EFMApp"]),
    ],
    targets: [
        .target(
            name: "CEFM",
            cSettings: [.unsafeFlags(["-O3"])]
        ),
        .target(name: "EFMQuery"),
        .target(
            name: "EFMCore",
            dependencies: ["CEFM", "EFMQuery"],
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        ),
        .executableTarget(name: "efm", dependencies: ["EFMCore"]),
        .executableTarget(
            name: "EFMApp",
            dependencies: ["EFMCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Quartz"),
            ]
        ),
        .testTarget(name: "EFMQueryTests", dependencies: ["EFMQuery"]),
        .testTarget(name: "EFMCoreTests", dependencies: ["EFMCore"]),
    ],
    swiftLanguageModes: [.v5]
)
