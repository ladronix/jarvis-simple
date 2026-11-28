// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "JarvisCore", targets: ["JarvisCore"]),
        .executable(name: "jarvis-cli", targets: ["jarvis-cli"]),
    ],
    // Exact versions live in Package.resolved (committed). Builds must not re-resolve:
    // `swift build --only-use-versions-from-resolved-file`, and scripts/build.sh and
    // scripts/package.sh pass `-onlyUsePackageVersionsFromResolvedFile` to xcodebuild.
    // Update deliberately with `swift package update` and review the diff.
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        // 0.x: minor versions may break the API. No traits: only VAD is used, so the prebuilt
        // text-normalization binary, text-to-speech and diarization are not built or linked.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.18.4"), traits: []),
    ],
    targets: [
        .target(
            name: "JarvisCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "jarvis-cli",
            dependencies: [
                "JarvisCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore"],
            resources: [.copy("../Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
