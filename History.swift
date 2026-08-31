import SwiftUI
import AVFoundation

struct Entry: Codable, Identifiable {
    var id: String { audio }
    var audio: String            // filename inside historyDir
    var text: String
    var date: Date
    var duration: Double? = nil  // optional so older history.json still decodes
}

// Tests redirect this so they never touch real recordings.
let historyRoot = ProcessInfo.processInfo.environment["VOICEKEY_HOME"]
    .map { URL(fileURLWithPath: $0) } ?? configDir
let historyDir = historyRoot.appendingPathComponent("history")
let historyURL = historyRoot.appendingPathComponent("history.json")
let historyLimit = 50

final class History: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = History()
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var playing: String?
    private var player: AVAudioPlayer?

    private override init() {
        super.init()
        try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: historyURL),
           let e = try? JSONDecoder().decode([Entry].self, from: d) { entries = e }
    }

    func url(_ e: Entry) -> URL { historyDir.appendingPathComponent(e.audio) }

    func add(audio: URL, text: String) {
        let seconds = (try? AVAudioFile(forReading: audio)).map {
            Double($0.length) / $0.fileFormat.sampleRate
        }
        entries.insert(Entry(audio: audio.lastPathComponent, text: text,
                             date: Date(), duration: seconds), at: 0)
        trim()
        save()
    }

    /// Keeps the newest `historyLimit` entries and deletes the audio of the rest.
    func trim() {
        guard entries.count > historyLimit else { return }
        for e in entries[historyLimit...] { try? FileManager.default.removeItem(at: url(e)) }
        entries.removeSubrange(historyLimit...)
    }

    func delete(_ e: Entry) {
        if playing == e.id { stop() }
        try? FileManager.default.removeItem(at: url(e))
        entries.removeAll { $0.id == e.id }
        save()
    }

    func clear() {
        stop()
        for e in entries { try? FileManager.default.removeItem(at: url(e)) }
        entries = []
        save()
    }

    func toggle(_ e: Entry) {
        if playing == e.id { stop(); return }
        player = try? AVAudioPlayer(contentsOf: url(e))
        player?.delegate = self
        player?.play()
        playing = player == nil ? nil : e.id
    }

    func stop() {
        player?.stop(); player = nil; playing = nil
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) {
        playing = nil
    }

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        try? enc.encode(entries).write(to: historyURL)
    }
}

// ---------- window ----------

struct Row: View {
    let entry: Entry
    @ObservedObject var history = History.shared
    @State private var hovering = false

    var isPlaying: Bool { history.playing == entry.id }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { history.toggle(entry) } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? T("Stop") : T("Play recording"))

            VStack(alignment: .leading, spacing: 3) {
                if entry.text.isEmpty {
                    Text(T("No speech detected"))
                        .italic().foregroundStyle(.tertiary)
                } else {
                    Text(entry.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Text(entry.date.formatted(.relative(presentation: .named)))
                    if let d = entry.duration {
                        Text("·")
                        Text(String(format: "%.1fs", d))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                Button { copy(entry.text) } label: { Image(systemName: "doc.on.doc") }
                    .help(T("Copy text")).disabled(entry.text.isEmpty)
                Button { history.delete(entry) } label: { Image(systemName: "trash") }
                    .help(T("Delete"))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isPlaying ? Color.accentColor.opacity(0.12)
                            : (hovering ? Color.primary.opacity(0.05) : .clear)))
        .onHover { hovering = $0 }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct HistoryView: View {
    @ObservedObject var history = History.shared
    @State private var query = ""

    var shown: [Entry] {
        query.isEmpty ? history.entries
            : history.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(T("Search transcripts"), text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            if shown.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: history.entries.isEmpty ? "waveform" : "magnifyingglass")
                        .font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(history.entries.isEmpty
                         ? T("Nothing recorded yet.\nHold your key and talk.")
                         : "\(T("No transcript matches")) “\(query)”.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { Row(entry: $0) }
                    }
                    .padding(6)
                }
            }

            Divider()
            HStack {
                Text("\(history.entries.count) \(T("of")) \(historyLimit) \(T("kept"))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(T("Clear all")) { history.clear() }
                    .disabled(history.entries.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(minWidth: 460, minHeight: 340)
    }
}
