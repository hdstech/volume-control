// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VolumeControl",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "VolumeControl", targets: ["VolumeControl"]),
    ],
    targets: [
        .target(name: "CAtomics"),
        .target(name: "VolumeControlKit"),
        .executableTarget(
            name: "VolumeControl",
            dependencies: ["CAtomics", "VolumeControlKit"]
        ),
        .testTarget(
            name: "VolumeControlKitTests",
            dependencies: ["VolumeControlKit"]
        ),
    ]
)
