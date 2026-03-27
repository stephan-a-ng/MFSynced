// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MFSynced",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MFSynced",
            path: "Sources/MFSynced",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-framework", "-Xlinker", "Contacts"]),
            ]
        ),
        .testTarget(
            name: "MFSyncedTests",
            dependencies: ["MFSynced"],
            path: "Tests/MFSyncedTests"
        ),
    ]
)
