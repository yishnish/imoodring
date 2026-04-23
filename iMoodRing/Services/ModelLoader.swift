import Foundation

struct ModelVariant {
    let name: String
    let url: URL
    let filename: String
    let approximateSizeGB: Double
}

extension ModelVariant {
    // Gemma 3 1B GGUF Q4_K_M — ~900 MB, CPU-only fallback for constrained devices.
    static let gemma3_1b = ModelVariant(
        name: "Gemma 3 1B",
        url: URL(string: "https://huggingface.co/bartowski/google_gemma-3-1b-it-GGUF/resolve/main/google_gemma-3-1b-it-Q4_K_M.gguf")!,
        filename: "google_gemma-3-1b-it-Q4_K_M.gguf",
        approximateSizeGB: 0.9
    )

    // Gemma 4 E2B GGUF UD-IQ2_M — ~2.3 GB, Metal GPU via llama.cpp.
    static let e2b = ModelVariant(
        name: "Gemma 4 E2B",
        url: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-UD-IQ2_M.gguf")!,
        filename: "gemma-4-E2B-it-UD-IQ2_M.gguf",
        approximateSizeGB: 2.3
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

    private static let storageURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Models", isDirectory: true)
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
        let dest = Self.storageURL.appendingPathComponent(variant.filename)

        await MainActor.run { state = .downloading(progress: 0, detail: "Connecting…") }
        print("[ModelLoader] Starting download: \(variant.url)")

        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            let delegate = DownloadDelegate(
                dest: dest,
                onProgress: { [weak self] progress, detail in
                    Task { @MainActor in self?.state = .downloading(progress: progress, detail: detail) }
                },
                onComplete: { result in
                    continuation.resume(returning: result)
                }
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            delegate.retainedSession = session
            session.downloadTask(with: variant.url).resume()
        }

        switch result {
        case .success(let url):
            print("[ModelLoader] Download complete: \(url.path)")
            state = .ready(modelPath: url.path)
        case .failure(let error):
            print("[ModelLoader] Download failed: \(error)")
            state = .failed("Download error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let dest: URL
    private let onProgress: (Double, String) -> Void
    private let onComplete: (Result<URL, Error>) -> Void
    private var completed = false

    var retainedSession: URLSession?

    init(dest: URL, onProgress: @escaping (Double, String) -> Void, onComplete: @escaping (Result<URL, Error>) -> Void) {
        self.dest = dest
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        let mb = Double(written) / 1_048_576
        if total > 0 {
            let totalMB = Double(total) / 1_048_576
            let pct = Double(written) / Double(total)
            onProgress(pct, String(format: "%.0f / %.0f MB", mb, totalMB))
        } else {
            onProgress(0.5, String(format: "%.0f MB downloaded…", mb))
        }
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !completed else { return }
        completed = true
        retainedSession = nil
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            onComplete(.success(dest))
        } catch {
            onComplete(.failure(error))
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !completed, let error else { return }
        completed = true
        retainedSession = nil
        print("[ModelLoader] URLSession task error: \(error)")
        onComplete(.failure(error))
    }
}
