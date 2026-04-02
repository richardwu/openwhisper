import Foundation

enum WhisperModel: String, CaseIterable {
    case base
    case small
    case medium

    var fileName: String {
        switch self {
        case .base:   return "ggml-base.en.bin"
        case .small:  return "ggml-small.en-q5_1.bin"
        case .medium: return "ggml-medium.en-q5_0.bin"
        }
    }

    var downloadURL: URL {
        let base = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
        return URL(string: base + fileName)!
    }

    var displayName: String {
        switch self {
        case .base:   return "Base (142 MB, very fast)"
        case .small:  return "Small (181 MB, fast)"
        case .medium: return "Medium (514 MB, not as fast)"
        }
    }
}

@MainActor
@Observable
final class ModelManager {
    enum Mode {
        case live
        case ready
        case downloading(progress: Double)
        case missing
        case failed(message: String)
        case fixedPath(URL)
    }

    var isDownloading = false
    var downloadProgress: Double = 0
    var errorMessage: String?

    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration: Int = 0
    private let mode: Mode
    private let defaults: UserDefaults

    var selectedModel: WhisperModel {
        didSet {
            defaults.set(selectedModel.rawValue, forKey: "selectedModel")
        }
    }

    var isModelReady: Bool {
        switch mode {
        case .ready, .fixedPath:
            return true
        case .downloading, .missing, .failed:
            return false
        case .live:
            return modelFileURL != nil
        }
    }

    var modelFileURL: URL? {
        switch mode {
        case .fixedPath(let url):
            return url
        case .ready:
            // Return a sentinel URL for test mode — TranscriptionService stub won't use it
            return URL(fileURLWithPath: "/tmp/test-model.bin")
        case .downloading, .missing, .failed:
            return nil
        case .live:
            guard let dir = modelsDirectory else { return nil }
            let path = dir.appendingPathComponent(selectedModel.fileName)
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
            return nil
        }
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

    init(mode: Mode = .live, defaults: UserDefaults = .standard) {
        self.mode = mode
        self.defaults = defaults
        let stored = defaults.string(forKey: "selectedModel") ?? ""
        self.selectedModel = WhisperModel(rawValue: stored) ?? .small

        // Apply test mode initial state
        switch mode {
        case .downloading(let progress):
            self.isDownloading = true
            self.downloadProgress = progress
        case .failed(let message):
            self.errorMessage = message
        default:
            break
        }
    }

    func ensureModelAvailable() {
        guard case .live = mode else { return }
        if !isModelReady {
            startDownload()
        }
    }

    func selectModel(_ model: WhisperModel) {
        guard case .live = mode else { return }
        downloadTask?.cancel()
        downloadTask = nil
        downloadGeneration &+= 1
        selectedModel = model
        if !isModelReady {
            downloadTask = Task {
                await downloadModel()
            }
        } else {
            isDownloading = false
            downloadProgress = 1.0
        }
    }

    func startDownload() {
        guard case .live = mode else { return }
        downloadTask?.cancel()
        downloadTask = nil
        downloadGeneration &+= 1
        downloadTask = Task {
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

        let destinationURL = modelsDir.appendingPathComponent(selectedModel.fileName)

        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        let generation = self.downloadGeneration

        do {
            try Task.checkCancellation()

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300    // 5 min per chunk
            config.timeoutIntervalForResource = 3600  // 1 hour total
            let delegate = DownloadDelegate { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.downloadGeneration == generation else { return }
                    self.downloadProgress = progress
                }
            }

            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: OperationQueue.main)
            defer { session.invalidateAndCancel() }

            let (tempURL, response) = try await withTaskCancellationHandler {
                try await delegate.download(session: session, from: selectedModel.downloadURL)
            } onCancel: {
                session.invalidateAndCancel()
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)

            guard self.downloadGeneration == generation else { return }
            isDownloading = false
            downloadProgress = 1.0
        } catch is CancellationError {
            // Don't reset isDownloading — the replacement download will take over
        } catch let error as URLError where error.code == .cancelled {
            // Don't reset isDownloading — the replacement download will take over
        } catch {
            guard self.downloadGeneration == generation else { return }
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
            guard let response = downloadTask.response else {
                continuation?.resume(throwing: URLError(.badServerResponse))
                continuation = nil
                return
            }
            continuation?.resume(returning: (tempFile, response))
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
