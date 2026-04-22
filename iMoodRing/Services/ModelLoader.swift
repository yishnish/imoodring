import Foundation

struct ModelVariant {
    let name: String
    let url: URL
    let filename: String
    let approximateSizeGB: Double
}

extension ModelVariant {
    // Gemma 4 E2B — default, ~2 GB, suitable for most iPhones
    // Model card: https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm
    // NOTE: MediaPipe LLM Inference uses the mobile .task file; verify the URL is
    // the mobile-optimized variant if Google publishes a separate one on Kaggle.
    static let e2b = ModelVariant(
        name: "Gemma 4 E2B",
        url: URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it-web.task")!,
        filename: "gemma-4-E2B-it.task",
        approximateSizeGB: 2.0
    )

    // Gemma 4 E4B — enhanced, ~3.6 GB, better quality
    static let e4b = ModelVariant(
        name: "Gemma 4 E4B",
        url: URL(string: "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it-web.task")!,
        filename: "gemma-4-E4B-it.task",
        approximateSizeGB: 3.6
    )
}

@Observable
final class ModelLoader {
    enum State {
        case idle
        case downloading(progress: Double, detail: String)
        case ready(modelPath: String)
        case failed(String)
    }

    var state: State = .idle

    private var downloadTask: URLSessionDownloadTask?

    private static let storageURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
    }()

    func localPath(for variant: ModelVariant) -> String {
        Self.storageURL.appendingPathComponent(variant.filename).path
    }

    func isDownloaded(_ variant: ModelVariant) -> Bool {
        FileManager.default.fileExists(atPath: localPath(for: variant))
    }

    func load(_ variant: ModelVariant) async {
        let path = localPath(for: variant)
        if FileManager.default.fileExists(atPath: path) {
            state = .ready(modelPath: path)
            return
        }
        await download(variant)
    }

    func deleteModel(_ variant: ModelVariant) {
        try? FileManager.default.removeItem(atPath: localPath(for: variant))
    }

    private func download(_ variant: ModelVariant) async {
        try? FileManager.default.createDirectory(at: Self.storageURL, withIntermediateDirectories: true)

        let delegate = DownloadDelegate { [weak self] progress, detail in
            Task { @MainActor in self?.state = .downloading(progress: progress, detail: detail) }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        state = .downloading(progress: 0, detail: "Starting…")

        do {
            let (tempURL, response) = try await session.download(from: variant.url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                state = .failed("Download failed — unexpected server response")
                return
            }
            let dest = Self.storageURL.appendingPathComponent(variant.filename)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            state = .ready(modelPath: dest.path)
        } catch {
            state = .failed("Download error: \(error.localizedDescription)")
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double, String) -> Void
    init(_ onProgress: @escaping (Double, String) -> Void) { self.onProgress = onProgress }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite total: Int64) {
        let progress = total > 0 ? Double(totalBytesWritten) / Double(total) : 0
        let mb = totalBytesWritten / 1_048_576
        let totalMB = total / 1_048_576
        onProgress(progress, "\(mb) / \(totalMB) MB")
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // File is moved by the async continuation in ModelLoader.download()
    }
}
