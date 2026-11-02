// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-step-audio-editx: StepFun's Step-Audio-EditX (Apache-2.0 weights) as a Gaea plugin on MES Audio 0.1's
// audio.edit_speech. One worker executable built on GaeaPluginKit over mlx-step-audio-editx-swift, packaged as a signed
// .gaeaplugin by scripts/build-plugin.sh.
//
// editx-inproc is not part of the plugin: it runs the same package in-process through MLXServeEngine, with the same
// dependency resolution and requests, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-step-audio-editx",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.8.0"),
        .package(url: "https://github.com/xocialize/mlx-step-audio-editx-swift.git", exact: "0.2.1"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.73.1"),
    ],
    targets: [
        .target(
            name: "EditXPlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXStepAudioEditX", package: "mlx-step-audio-editx-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-step-audio-editx-worker",
            dependencies: [
                "EditXPlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "editx-inproc",
            dependencies: [
                "EditXPlugin",
                .product(name: "GaeaProtocol", package: "gaea-plugin-kit"),
                .product(name: "MLXStepAudioEditX", package: "mlx-step-audio-editx-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "EditXPluginTests", dependencies: ["EditXPlugin", .product(name: "MLXStepAudioEditX", package: "mlx-step-audio-editx-swift")]),
    ]
)
