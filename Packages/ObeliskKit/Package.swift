// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ObeliskKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ObeliskCore", targets: ["ObeliskCore"]),
        .library(name: "ObeliskData", targets: ["ObeliskData"]),
        .library(name: "ObeliskSync", targets: ["ObeliskSync"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            from: "7.11.0"
        ),
    ],
    targets: [
        .target(name: "ObeliskCore"),
        .target(
            name: "ObeliskData",
            dependencies: [
                "ObeliskCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "ObeliskSync",
            dependencies: [
                "ObeliskCore",
                "ObeliskData",
            ]
        ),
        .testTarget(
            name: "ObeliskKitTests",
            dependencies: [
                "ObeliskCore",
                "ObeliskData",
                "ObeliskSync",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
