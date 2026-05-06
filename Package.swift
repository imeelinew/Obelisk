// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Obelisk",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Obelisk", targets: ["ObeliskMenu"]),
        .executable(name: "ObeliskSmokeTests", targets: ["ObeliskSmokeTests"])
    ],
    targets: [
        .target(name: "ObeliskCore"),
        .executableTarget(
            name: "ObeliskMenu",
            dependencies: ["ObeliskCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "ObeliskSmokeTests",
            dependencies: ["ObeliskCore"]
        )
    ]
)
