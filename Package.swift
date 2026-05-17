// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "duo-paste",
    platforms: [
        .macOS(.v14),
        .iOS(.v26),
    ],
    products: [
        .library(name: "DuoPasteCore", targets: ["DuoPasteCore"]),
        .library(name: "DuoPasteCapture", targets: ["DuoPasteCapture"]),
        .library(name: "DuoPasteSync", targets: ["DuoPasteSync"]),
        .executable(name: "duo-pasted", targets: ["duo-pasted"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.6.0"),
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
        .target(
            name: "DuoPasteSync",
            dependencies: [
                "DuoPasteCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "HummingbirdWSClient", package: "hummingbird-websocket"),
            ]
        ),
        .executableTarget(
            name: "duo-pasted",
            dependencies: [
                "DuoPasteCore",
                "DuoPasteCapture",
                "DuoPasteSync",
            ]
        ),
        .testTarget(
            name: "DuoPasteCoreTests",
            dependencies: ["DuoPasteCore"]
        ),
        .testTarget(
            name: "DuoPasteSyncTests",
            dependencies: [
                "DuoPasteSync",
                "DuoPasteCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
