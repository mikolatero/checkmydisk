// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CheckMyDisk",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CheckMyDisk", targets: ["CheckMyDisk"]),
        .executable(name: "CheckMyDiskHelper", targets: ["CheckMyDiskHelper"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMajor(from: "2.9.4")),
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMajor(from: "7.0.0"))
    ],
    targets: [
        .executableTarget(
            name: "CheckMyDisk",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/CheckMyDisk",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "CheckMyDiskHelper",
            path: "Sources/CheckMyDiskHelper"
        ),
        .testTarget(
            name: "CheckMyDiskTests",
            dependencies: ["CheckMyDisk"],
            path: "Tests/CheckMyDiskTests"
        )
    ]
)
