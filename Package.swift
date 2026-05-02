// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UniBookmark",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "UniBookmarkMenu", targets: ["UniBookmarkMenu"])
    ],
    targets: [
        .target(name: "UniBookmarkCore"),
        .executableTarget(
            name: "UniBookmarkMenu",
            dependencies: ["UniBookmarkCore"]
        )
    ]
)
