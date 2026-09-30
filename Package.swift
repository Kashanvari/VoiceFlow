// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceFlow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoiceFlow", targets: ["VoiceFlow"]),
        .executable(name: "VoiceFlowCheck", targets: ["VoiceFlowCheck"]),
    ],
    dependencies: [
        // 0.8.2 is the version that loaded the Parakeet v2 files in models/.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.8.2"),
        // Whisper (large-v3 turbo) for Farsi, which Parakeet can't do. Loads the files in models/whisperkit.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0"),
    ],
    targets: [
        // Speech-to-text, clean-up and audio helpers, shared by the app and the check tool.
        .target(name: "VoiceFlowCore", dependencies: ["FluidAudio", .product(name: "WhisperKit", package: "WhisperKit")]),
        // Tiny Objective-C helper that turns Core Audio exceptions into errors instead of crashes.
        .target(name: "VFObjC"),
        // The app.
        .executableTarget(name: "VoiceFlow", dependencies: ["VoiceFlowCore", "VFObjC"]),
        // Command-line check: speaks test sentences with macOS `say` and runs them through the pipeline.
        .executableTarget(name: "VoiceFlowCheck", dependencies: ["VoiceFlowCore"]),
    ]
)
