import Foundation

@MainActor
@Observable
final class ModelManager {
    var isDownloading = false
    var downloadProgress: Double = 0
    var errorMessage: String?

    private static let modelFileName = "ggml-base.en.bin"
    private static let modelDownloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!

    var isModelReady: Bool {
        guard let url = modelFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    var modelFileURL: URL? {
        guard let dir = modelsDirectory else { return nil }
        return dir.appendingPathComponent(Self.modelFileName)
    }

    private var modelsDirectory: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }

        return appSupport
            .appendingPathComponent("OpenWhisper")
            .appendingPathComponent("Models")
    }

    func ensureModelAvailable() async {
        if !isModelReady {
            await downloadModel()
        }
    }

    func downloadModel() async {
        guard let modelsDir = modelsDirectory else {
            errorMessage = "Cannot determine models directory"
            return
        }

        // Create directory if needed
        do {
            try FileManager.default.createDirectory(
                at: modelsDir,
                withIntermediateDirectories: true
            )
        } catch {
            errorMessage = "Cannot create models directory: \(error.localizedDescription)"
            return
        }

        let destinationURL = modelsDir.appendingPathComponent(Self.modelFileName)

        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(from: Self.modelDownloadURL)

            let expectedLength = response.expectedContentLength
            var data = Data()
            if expectedLength > 0 {
                data.reserveCapacity(Int(expectedLength))
            }

            for try await byte in asyncBytes {
                data.append(byte)
                if expectedLength > 0 {
                    downloadProgress = Double(data.count) / Double(expectedLength)
                }
            }

            try data.write(to: destinationURL, options: .atomic)
            isDownloading = false
            downloadProgress = 1.0
        } catch {
            isDownloading = false
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }
}
