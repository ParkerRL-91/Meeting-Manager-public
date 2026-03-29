// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MeetingManager",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "MeetingManager",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "MeetingManager",
            exclude: ["Resources/Info.plist", "Resources/MeetingManager.entitlements"],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "MeetingManagerTests",
            dependencies: [
                "MeetingManager",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/MeetingManagerTests"
        ),
    ]
)
