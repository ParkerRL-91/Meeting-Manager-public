// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MeetingManager",
    platforms: [
        .macOS("14.4"),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "MeetingManager",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
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
        .testTarget(
            name: "MeetingDetectionTests",
            dependencies: [
                "MeetingManager",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/MeetingDetectionTests"
        ),
        // CLI tool used by the WER evaluation harness.
        // Build: swift build --product transcribe-audio
        // Usage: .build/debug/transcribe-audio path/to/audio.aiff
        .executableTarget(
            name: "transcribe-audio",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Tools/TranscribeAudio"
        ),
        // Developer-only prompt-optimization harness (ADR-007 follow-up).
        // Runs candidate prompts against fixture transcripts via the local
        // Ollama HTTP API and scores each result on deterministic rubrics.
        // No new SPM dependencies; doesn't ship in the app bundle.
        // Build: swift build --product prompt-eval
        // Usage: .build/debug/prompt-eval --prompt action-item --model qwen3:8b
        .executableTarget(
            name: "prompt-eval",
            path: "Tests/PromptOptimization",
            exclude: ["Fixtures", "results"]
        ),
        // Phase 0 gate spike — verifies FluidAudio resolves, links with
        // WhisperKit, and its diarization/enrollment API works on real audio.
        // Not shipped in the app bundle. Removed after the gate decision.
        .executableTarget(
            name: "fluid-spike",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Tools/FluidSpike"
        ),
    ]
)
