// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "duo-paste",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DuoPasteCore", targets: ["DuoPasteCore"]),
        .library(name: "DuoPasteCapture", targets: ["DuoPasteCapture"]),
        .executable(name: "duo-pasted", targets: ["duo-pasted"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
    ],
    targets: [
        .target(
            name: "DuoPasteCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "DuoPasteCapture",
            dependencies: ["DuoPasteCore"]
        ),
        .executableTarget(
            name: "duo-pasted",
            dependencies: [
                "DuoPasteCore",
                "DuoPasteCapture",
            ]
        ),
        .testTarget(
            name: "DuoPasteCoreTests",
            dependencies: ["DuoPasteCore"]
        ),
    ]
)
