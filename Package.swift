// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Casa",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Casa",
            path: "Sources/Casa",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // Trait 01 is a launch-time budget. Optimize even in debug so the
                // numbers we measure while developing mean something.
                .unsafeFlags(["-Onone"], .when(configuration: .debug)),
            ]
        )
    ]
)
