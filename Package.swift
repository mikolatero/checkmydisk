// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CheckMyDisk",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CheckMyDisk", targets: ["CheckMyDisk"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMajor(from: "2.9.4"))
    ],
    targets: [
        .executableTarget(
            name: "CheckMyDisk",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/CheckMyDisk",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CheckMyDiskTests",
            dependencies: ["CheckMyDisk"],
            path: "Tests/CheckMyDiskTests"
        )
    ]
)
