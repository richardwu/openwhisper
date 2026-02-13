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
        modelFileURL != nil
    }

    var modelFileURL: URL? {
        // 1. Bundled model (release builds)
        if let bundled = Bundle.main.url(forResource: "ggml-base.en", withExtension: "bin") {
            return bundled
        }
        // 2. Downloaded model (dev fallback)
        guard let dir = modelsDirectory else { return nil }
        let downloaded = dir.appendingPathComponent(Self.modelFileName)
        if FileManager.default.fileExists(atPath: downloaded.path) {
            return downloaded
        }
        return nil
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

        do {
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Cannot create models directory: \(error.localizedDescription)"
            return
        }

        let destinationURL = modelsDir.appendingPathComponent(Self.modelFileName)

        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        do {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300    // 5 min per chunk
            config.timeoutIntervalForResource = 3600  // 1 hour total

            let delegate = DownloadDelegate { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                }
            }

            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }

            let (tempURL, response) = try await delegate.download(session: session, from: Self.modelDownloadURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)

            isDownloading = false
            downloadProgress = 1.0
        } catch {
            isDownloading = false
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func download(session: URLSession, from url: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Copy to a stable temp location — the file at `location` is deleted when this method returns
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        do {
            try FileManager.default.copyItem(at: location, to: tempFile)
            continuation?.resume(returning: (tempFile, downloadTask.response!))
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
