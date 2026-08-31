import Foundation

/// The models worth offering, smallest first. base.en and small.en are English-only
/// and mangle Vietnamese, so the multilingual turbo model is the default.
let downloadableModels: [(name: String, size: String)] = [
    ("tiny.en", "75 MB"), ("base.en", "142 MB"), ("small", "466 MB"),
    ("medium", "1.5 GB"), ("large-v3-turbo-q5_0", "547 MB"),
]

/// What ./setup.sh does, minus the terminal: install whisper-cpp with Homebrew and
/// download a model. Both steps are skipped when they're already satisfied.
final class Installer: NSObject, ObservableObject {
    static let shared = Installer()

    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var progress = 0.0      // 0…1 while a model downloads

    private var task: URLSessionDownloadTask?
    private var dest: URL?

    /// Homebrew lives in a different place on Apple silicon and Intel, and the app
    /// doesn't inherit the user's PATH, so look it up by hand.
    static func find(_ tool: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"]
            .map { $0 + tool }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func cancel() {
        task?.cancel(); task = nil
        if let dest { try? FileManager.default.removeItem(at: dest) }
        busy = false; progress = 0; status = T("Cancelled.")
    }

    /// Step 1 — whisper-cli. Runs brew synchronously off the main thread; brew can
    /// take minutes on a cold install, hence the running status text.
    func install(model: String) {
        guard !busy else { return }
        busy = true; progress = 0; status = T("Looking for whisper-cli…")

        DispatchQueue.global().async {
            var cli = Installer.find("whisper-cli")
            if cli == nil {
                guard let brew = Installer.find("brew") else {
                    return self.finish(T("Homebrew not found. Install it from brew.sh, then try again."))
                }
                DispatchQueue.main.async { self.status = T("Installing whisper-cpp with Homebrew…") }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: brew)
                p.arguments = ["install", "whisper-cpp"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch {
                    return self.finish(T("Could not run brew: ") + error.localizedDescription)
                }
                p.waitUntilExit()
                cli = Installer.find("whisper-cli")
                guard p.terminationStatus == 0, cli != nil else {
                    return self.finish(T("brew install whisper-cpp failed — run it in a terminal to see why."))
                }
            }
            DispatchQueue.main.async {
                Settings.shared.cfg.whisper = cli!
                Settings.shared.save()
                self.download(model)
            }
        }
    }

    /// Step 2 — the ggml weights. Downloaded to the same path setup.sh uses, so the
    /// two ways of installing don't fight over the file.
    private func download(_ model: String) {
        let dir = configDir.appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("ggml-\(model).bin")

        if FileManager.default.fileExists(atPath: file.path) {
            Settings.shared.cfg.model = file.path
            Settings.shared.save()
            return finish(T("Ready — model already downloaded."))
        }

        status = "\(T("Downloading")) ggml-\(model).bin…"
        dest = file
        let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(model).bin")!
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        task = session.downloadTask(with: url)
        task?.resume()
    }

    private func finish(_ message: String) {
        DispatchQueue.main.async {
            self.busy = false; self.progress = 0; self.status = message; self.task = nil
        }
    }
}

extension Installer: URLSessionDownloadDelegate {
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten written: Int64,
                    totalBytesExpectedToWrite total: Int64) {
        guard total > 0 else { return }
        DispatchQueue.main.async { self.progress = Double(written) / Double(total) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo tmp: URL) {
        guard let dest, (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            return finish(T("Download failed — check your connection and try again."))
        }
        // Move it off the delegate queue's temp file before this method returns.
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            return finish(T("Could not save the model: ") + error.localizedDescription)
        }
        DispatchQueue.main.async {
            Settings.shared.cfg.model = dest.path
            Settings.shared.save()
            self.finish(T("Ready — whisper and the model are installed."))
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        finish(T("Download failed: ") + error.localizedDescription)
    }
}
