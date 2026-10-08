// swift-tools-version: 5.9
import PackageDescription

// OpenWhisper uses Handy's official Swift wrapper around the local
// transcribe.cpp runtime. The release xcframework is vendored so builds do not
// depend on a cloud service or a machine-specific native toolchain.
let package = Package(
    name: "TranscribeCpp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TranscribeCpp", targets: ["TranscribeCpp"]),
    ],
    targets: [
        .binaryTarget(name: "CTranscribe", path: "TranscribeCpp.xcframework"),
        .target(
            name: "TranscribeCpp",
            dependencies: ["CTranscribe"],
            path: "Sources/TranscribeCpp",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
    ]
)
