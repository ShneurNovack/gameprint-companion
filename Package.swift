// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GamePrintCompanion",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "GamePrintCompanion", targets: ["GamePrintCompanion"]),
        .executable(name: "gpctl", targets: ["gpctl"]),
    ],
    targets: [
        .systemLibrary(name: "CCups", path: "Sources/CCups"),
        .target(
            name: "PrintCore",
            dependencies: ["CCups"],
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedLibrary("cups")]
        ),
        .executableTarget(name: "GamePrintCompanion", dependencies: ["PrintCore"]),
        .executableTarget(name: "gpctl", dependencies: ["PrintCore"]),
        .testTarget(name: "PrintCoreTests", dependencies: ["PrintCore"]),
    ]
)
