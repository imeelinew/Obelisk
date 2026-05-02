// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UniBookmark",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "UniBookmarkMenu", targets: ["UniBookmarkMenu"]),
        .executable(name: "UniBookmarkSmokeTests", targets: ["UniBookmarkSmokeTests"])
    ],
    targets: [
        .target(name: "UniBookmarkCore"),
        .executableTarget(
            name: "UniBookmarkMenu",
            dependencies: ["UniBookmarkCore"]
        ),
        .executableTarget(
            name: "UniBookmarkSmokeTests",
            dependencies: ["UniBookmarkCore"]
        )
    ]
)
