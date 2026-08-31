import SwiftUI

/// Aggregate counters only — no transcript text, so Privacy Mode still counts.
struct Stat: Codable {
    var words = 0
    var seconds = 0.0                    // time actually spent speaking
    var days: [String: Int] = [:]        // "yyyy-MM-dd" -> words that day
    var apps: [String: Int] = [:]        // app name -> words dictated into it
}

private let dayFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
}()

/// A fast typist does ~40 wpm of prose; anything above that is time dictation saved.
let typingWPM = 40.0
let wordsPerLevel = 500
let levelNames = ["Whisper", "Mumbler", "Chatterbox", "Podcaster", "Auctioneer", "Town Crier"]

final class StatStore: ObservableObject {
    static let shared = StatStore()
    private let url = historyRoot.appendingPathComponent("stats.json")
    @Published private(set) var stat = Stat()

    private init() {
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Stat.self, from: d) {
            stat = s
        }
    }

    func record(words: Int, seconds: Double, app: String?) {
        guard words > 0 else { return }
        stat.words += words
        stat.seconds += seconds
        stat.days[dayFmt.string(from: Date()), default: 0] += words
        if let app { stat.apps[app, default: 0] += words }
        try? JSONEncoder().encode(stat).write(to: url)
        objectWillChange.send()
    }

    func reset() {
        stat = Stat()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: derived

    var today: Int { stat.days[dayFmt.string(from: Date())] ?? 0 }
    var wpm: Int { stat.seconds > 0 ? Int(Double(stat.words) / stat.seconds * 60) : 0 }
    var topApp: String? { stat.apps.max { $0.value < $1.value }?.key }
    var level: Int { stat.words / wordsPerLevel + 1 }
    var levelName: String { levelNames[min(level - 1, levelNames.count - 1)] }
    var toNextLevel: Int { level * wordsPerLevel - stat.words }
    var levelProgress: Double { Double(stat.words % wordsPerLevel) / Double(wordsPerLevel) }

    /// Seconds of typing avoided: how long the same words would have taken to type.
    var timeSaved: Double { max(0, Double(stat.words) / typingWPM * 60 - stat.seconds) }

    /// Consecutive days ending today (or yesterday, so an unused morning doesn't reset it).
    var streak: Int {
        var n = 0
        var day = Date()
        if stat.days[dayFmt.string(from: day)] == nil { day.addTimeInterval(-86400) }
        while stat.days[dayFmt.string(from: day)] != nil {
            n += 1
            day.addTimeInterval(-86400)
        }
        return n
    }
}

func shortDuration(_ s: Double) -> String {
    let t = Int(s.rounded())
    if t < 60 { return "\(t)s" }
    if t < 3600 { return "\(t / 60)m \(t % 60)s" }
    return "\(t / 3600)h \(t % 3600 / 60)m"
}

// ---------- view ----------

struct Tile: View {
    let label: String, value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// GitHub-style contribution grid: 53 weeks of columns, Sun-top rows, ending today.
struct HeatmapView: View {
    let days: [String: Int]
    private let cell = 11.0, gap = 3.0, weeks = 53

    /// Dates for every cell, oldest first, starting on the Sunday of the earliest week.
    private var grid: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day,
                             value: -((weeks - 1) * 7 + cal.component(.weekday, from: today) - 1),
                             to: today)!
        return (0..<(weeks * 7)).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private var peak: Int { max(days.values.max() ?? 0, 1) }

    private func color(_ date: Date) -> Color {
        guard date <= Date() else { return .clear }
        let n = days[dayFmt.string(from: date)] ?? 0
        if n == 0 { return Color.secondary.opacity(0.15) }
        // 4 filled levels, quartiles of the busiest day
        let level = min(4, Int(ceil(Double(n) / Double(peak) * 4)))
        return Color.accentColor.opacity([0.3, 0.5, 0.75, 1.0][level - 1])
    }

    var body: some View {
        let cells = grid
        HStack(alignment: .top, spacing: gap) {
            VStack(alignment: .trailing, spacing: gap) {
                Text("").frame(height: 12)                       // month-label gutter
                ForEach(0..<7, id: \.self) { row in
                    Text(["", "Mon", "", "Wed", "", "Fri", ""][row])
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                        .frame(height: cell)
                }
            }
            ForEach(0..<weeks, id: \.self) { w in
                VStack(spacing: gap) {
                    Text(monthLabel(cells[w * 7]))
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                        .fixedSize().frame(width: cell, height: 12, alignment: .leading)
                    ForEach(0..<7, id: \.self) { d in
                        let date = cells[w * 7 + d]
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(date))
                            .frame(width: cell, height: cell)
                            .help("\(dayFmt.string(from: date)): \(days[dayFmt.string(from: date)] ?? 0) \(T("words"))")
                    }
                }
            }
        }
    }

    /// Label only on the first column that lands in a new month.
    private func monthLabel(_ sunday: Date) -> String {
        let cal = Calendar.current
        guard let prev = cal.date(byAdding: .day, value: -7, to: sunday),
              cal.component(.month, from: prev) != cal.component(.month, from: sunday) else { return "" }
        return sunday.formatted(.dateTime.month(.abbreviated))
    }
}

struct StatsView: View {
    @ObservedObject var store = StatStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(T("Total Words"))
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("\(store.stat.words)")
                            .font(.system(size: 54, weight: .light))
                    }
                    Spacer()
                    Text("\(T("VoiceKey saved you"))\n**\(shortDuration(store.timeSaved))** \(T("of typing."))")
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(store.toNextLevel) \(T("words to Lv."))\(store.level + 1)")
                        Spacer()
                        if store.today > 0 {
                            Text("+\(store.today) \(T("today"))").foregroundStyle(Color.accentColor)
                        }
                    }
                    .font(.caption)

                    ProgressView(value: store.levelProgress)
                    Text("\(T("Level")) \(store.level): \(store.levelName)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                HStack(spacing: 0) {
                    Tile(label: "WPM", value: "\(store.wpm)")
                    Tile(label: T("Top App"), value: store.topApp ?? "—")
                    Tile(label: T("Streak"), value: "\(store.streak) \(T(store.streak == 1 ? "day" : "days"))")
                    Tile(label: T("Spoken"), value: shortDuration(store.stat.seconds))
                }

                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HeatmapView(days: store.stat.days).padding(.bottom, 2)
                    }
                    .defaultScrollAnchor(.trailing)
                    HStack(spacing: 3) {
                        Spacer()
                        Text(T("Less")).font(.system(size: 9)).foregroundStyle(.secondary)
                        ForEach([0.15, 0.3, 0.5, 0.75, 1.0], id: \.self) { o in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(o == 0.15 ? Color.secondary.opacity(o) : Color.accentColor.opacity(o))
                                .frame(width: 11, height: 11)
                        }
                        Text(T("More")).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }

                if store.stat.words == 0 {
                    Text(T("Nothing dictated yet — hold a key and talk."))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
                Button(T("Reset stats")) { store.reset() }
                    .foregroundStyle(.red)
            }
            .padding(28)
        }
    }
}
