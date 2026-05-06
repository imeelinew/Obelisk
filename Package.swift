// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UniBookmark",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "UniBookmarkMenu", targets: ["UniBookmarkMenu"]),
        .executable(name: "UniBookmarkSmokeTests", targets: ["UniBookmarkSmokeTests"])
    ],
    targets: [
        .target(name: "UniBookmarkCore"),
        .executableTarget(
            name: "UniBookmarkMenu",
            dependencies: ["UniBookmarkCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "UniBookmarkSmokeTests",
            dependencies: ["UniBookmarkCore"]
        )
    ]
)
