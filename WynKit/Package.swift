// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WynKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WynKit", targets: ["WynKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/SwiftPackageIndex/SemanticVersion.git", from: "0.3.0")
    ],
    targets: [
        .target(
            name: "WynKit",
            dependencies: ["SemanticVersion"],
            resources: [.process("Resources")]
        )
    ],
    swiftLanguageVersions: [.version("6")]
)
