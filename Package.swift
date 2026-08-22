// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Wyn",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "wyn", targets: ["WynCmd"])
    ],
    dependencies: [
        .package(path: "WynKit"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/scottrhoyt/SwiftyTextTable", from: "0.9.0"),
        .package(url: "https://github.com/SwiftPackageIndex/SemanticVersion.git", from: "0.3.0")
    ],
    targets: [
        .executableTarget(
            name: "WynCmd",
            dependencies: [
                "WynKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftyTextTable", package: "SwiftyTextTable"),
                .product(name: "SemanticVersion", package: "SemanticVersion")
            ]
        )
    ],
    swiftLanguageVersions: [.version("6")]
)
