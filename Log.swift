import Foundation

/// Append-only log at ~/.config/voicekey/voicekey.log. Deliberately dumb: one
/// handle, one queue, no rotation library. Tail it with:
///   tail -f ~/.config/voicekey/voicekey.log
let logURL = historyRoot.appendingPathComponent("voicekey.log")

private let logQueue = DispatchQueue(label: "voicekey.log")
private let logStamp: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
}()

func log(_ message: String) {
    let line = "\(logStamp.string(from: Date()))  \(message)\n"
    logQueue.async {
        FileHandle.standardError.write(Data(line.utf8))
        // Keep it from growing forever: truncate once past ~1 MB.
        if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int,
           size > 1_000_000 { try? FileManager.default.removeItem(at: logURL) }
        guard let h = try? FileHandle(forWritingTo: logURL) else {
            try? Data(line.utf8).write(to: logURL); return
        }
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    }
}
