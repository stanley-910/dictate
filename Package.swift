// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dictate",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dictate", targets: ["dictate"]),
    ],
    targets: [
        // Prebuilt transcribe.cpp (ggml + Metal). Fetched by scripts/fetch-deps.sh.
        .binaryTarget(name: "CTranscribe", path: "Vendor/TranscribeCpp.xcframework"),
        // Upstream Swift wrapper, vendored verbatim from transcribe.cpp bindings/swift.
        .target(
            name: "TranscribeCpp",
            dependencies: ["CTranscribe"],
            path: "Vendor/TranscribeCpp",
            exclude: ["LICENSE"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .executableTarget(
            name: "dictate",
            dependencies: ["TranscribeCpp"],
            path: "Sources/dictate",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
