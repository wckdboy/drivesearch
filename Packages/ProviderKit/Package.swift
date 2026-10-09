// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProviderKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ProviderKit", targets: ["ProviderKit"]),
    ],
    targets: [
        .target(
            name: "ProviderKit",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "ProviderKitTests",
            dependencies: ["ProviderKit"]
        ),
    ]
)
