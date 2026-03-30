import Foundation
import SwiftWhisper

enum WhisperModel: String, CaseIterable {
    case base
    case small
    case medium

    var fileName: String {
        switch self {
        case .base:   return "ggml-base.bin"
        case .small:  return "ggml-small-q5_1.bin"
        case .medium: return "ggml-medium-q5_0.bin"
        }
    }

    var downloadURL: URL {
        let base = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
        return URL(string: base + fileName)!
    }

    var displayName: String {
        switch self {
        case .base:   return "Base (148 MB, very fast)"
        case .small:  return "Small (163 MB, fast)"
        case .medium: return "Medium (568 MB, not as fast)"
        }
    }
}

@MainActor
@Observable
final class ModelManager {
    private enum DefaultsKey {
        static let selectedModel = "selectedModel"
        static let selectedLanguage = "selectedLanguage"
        static let didMigrateToMultilingual = "didMigrateToMultilingual"
    }

    private static let legacyEnglishModelFileNames = [
        "ggml-base.en.bin",
        "ggml-small.en-q5_1.bin",
        "ggml-medium.en-q5_0.bin",
    ]

    var isDownloading = false
    var downloadProgress: Double = 0
    var errorMessage: String?

    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration: Int = 0

    var selectedModel: WhisperModel {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: DefaultsKey.selectedModel)
        }
    }

    var selectedLanguage: WhisperLanguage {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: DefaultsKey.selectedLanguage)
        }
    }

    var isModelReady: Bool {
        modelFileURL != nil
    }

    var modelFileURL: URL? {
        guard let dir = modelsDirectory else { return nil }
        let path = dir.appendingPathComponent(selectedModel.fileName)
        if FileManager.default.fileExists(atPath: path.path) {
            return path
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

    init() {
        let defaults = UserDefaults.standard
        let storedModel = defaults.string(forKey: DefaultsKey.selectedModel) ?? ""
        let storedLanguage = defaults.string(forKey: DefaultsKey.selectedLanguage) ?? ""

        self.selectedModel = WhisperModel(rawValue: storedModel) ?? .small
        self.selectedLanguage = WhisperLanguage(rawValue: storedLanguage) ?? .auto

        migrateToMultilingualModelsIfNeeded(using: defaults)
    }

    func ensureModelAvailable() {
        if !isModelReady {
            startDownload()
        }
    }

    func selectModel(_ model: WhisperModel) {
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

    private func migrateToMultilingualModelsIfNeeded(using defaults: UserDefaults) {
        guard !defaults.bool(forKey: DefaultsKey.didMigrateToMultilingual) else { return }

        defer {
            defaults.set(true, forKey: DefaultsKey.didMigrateToMultilingual)
        }

        guard let modelsDirectory else { return }

        for legacyFileName in Self.legacyEnglishModelFileNames {
            let legacyURL = modelsDirectory.appendingPathComponent(legacyFileName)
            guard FileManager.default.fileExists(atPath: legacyURL.path) else { continue }

            do {
                try FileManager.default.removeItem(at: legacyURL)
            } catch {
                errorMessage = "Could not clean up old model files: \(error.localizedDescription)"
            }
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
