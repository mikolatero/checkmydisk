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
    targets: [
        .executableTarget(
            name: "CheckMyDisk",
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
