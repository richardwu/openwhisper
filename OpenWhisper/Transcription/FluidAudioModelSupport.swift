import Foundation

/// Files used by FluidAudio's Parakeet Unified streaming export.
///
/// FluidAudio keeps Core ML assets in its own application-support directory.
/// OpenWhisper checks the same cache before showing the model as available,
/// but FluidAudio remains responsible for downloading and loading the assets.
enum FluidAudioModelSupport {
    // This is FluidAudio's exact cache key for its Parakeet Unified export.
    // The package stores Core ML assets under this directory, without a
    // separate "coreml" suffix.
    static let repositoryName = "parakeet-unified-en-0.6b"
    static let requiredFiles = [
        "parakeet_unified_encoder_streaming_70_13_13_int8.mlmodelc",
        "parakeet_unified_decoder.mlmodelc",
        "parakeet_unified_joint_decision_single_step.mlmodelc",
        "vocab.json",
    ]

    static var modelsDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(repositoryName, isDirectory: true)
    }

    static var modelsAreAvailable: Bool {
        guard let modelsDirectory else { return false }
        let fileManager = FileManager.default
        return requiredFiles.allSatisfy { relativePath in
            let url = modelsDirectory.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: url.path) else { return false }
            // A compiled Core ML bundle can exist while its download is still
            // partial. FluidAudio uses the same marker for its cache checks.
            if relativePath.hasSuffix(".mlmodelc") {
                return fileManager.fileExists(
                    atPath: url.appendingPathComponent("coremldata.bin").path
                )
            }
            return true
        }
    }
}
