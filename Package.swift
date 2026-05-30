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
        // Sparkle 自动更新。SPM 包走 binaryTarget（下载预签 xcframework zip，不是源码
        // clone），避开 GRDB 那种弱网 clone 断流。只 link 到 duo-pasted（macOS 可执行），
        // iOS / 各 library target 不依赖它。版本跟 claude-usage 对齐（2.6.4 起）
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.4"),
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
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "DuoPasteCoreTests",
            dependencies: ["DuoPasteCore"]
        ),
        .testTarget(
            name: "DuoPasteCaptureTests",
            dependencies: ["DuoPasteCapture"]
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
