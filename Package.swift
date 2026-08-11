// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "keepitclean",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "keep", targets: ["KeepItCleanCLI"]),
        .library(name: "KeepItCleanCore", targets: ["KeepItCleanCore"]),
        .library(name: "KeepItCleanFS", targets: ["KeepItCleanFS"]),
        .library(name: "KeepItCleanRules", targets: ["KeepItCleanRules"]),
        .library(name: "KeepItCleanTUI", targets: ["KeepItCleanTUI"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            exact: "1.8.2"
        ),
    ],
    targets: [
        .target(name: "KeepItCleanCore"),
        .target(
            name: "KeepItCleanFS",
            dependencies: ["KeepItCleanCore"]
        ),
        .target(
            name: "KeepItCleanRules",
            dependencies: ["KeepItCleanCore", "KeepItCleanFS"]
        ),
        .target(
            name: "KeepItCleanTUI",
            dependencies: ["KeepItCleanCore"]
        ),
        .executableTarget(
            name: "KeepItCleanCLI",
            dependencies: [
                "KeepItCleanCore",
                "KeepItCleanFS",
                "KeepItCleanRules",
                "KeepItCleanTUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "KeepItCleanCoreTests",
            dependencies: ["KeepItCleanCore"]
        ),
        .testTarget(
            name: "KeepItCleanFSTests",
            dependencies: ["KeepItCleanCore", "KeepItCleanFS"]
        ),
        .testTarget(
            name: "KeepItCleanRulesTests",
            dependencies: ["KeepItCleanCore", "KeepItCleanFS", "KeepItCleanRules"]
        ),
        .testTarget(
            name: "KeepItCleanTUITests",
            dependencies: ["KeepItCleanCore", "KeepItCleanTUI"]
        ),
        .testTarget(
            name: "KeepItCleanCLITests",
            dependencies: ["KeepItCleanCLI", "KeepItCleanCore", "KeepItCleanFS"]
        ),
    ]
)
