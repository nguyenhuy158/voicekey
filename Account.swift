import SwiftUI

/// GitHub-style activity grid over the last N weeks, driven by StatStore.days.
struct Heatmap: View {
    let days: [String: Int]
    var weeks = 26

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// Columns of 7 days, oldest first, ending on today's column.
    var columns: [[Date]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Back up to the start of the week so rows line up with weekdays.
        let weekday = cal.component(.weekday, from: today) - cal.firstWeekday
        let start = cal.date(byAdding: .day,
                             value: -((weeks - 1) * 7 + (weekday + 7) % 7), to: today)!
        return (0..<weeks).map { w in
            (0..<7).compactMap { cal.date(byAdding: .day, value: w * 7 + $0, to: start) }
        }
    }

    func shade(_ date: Date) -> Color {
        guard let n = days[Self.fmt.string(from: date)], n > 0 else {
            return Color.primary.opacity(0.06)
        }
        let max = Double(days.values.max() ?? 1)
        return Color.accentColor.opacity(0.25 + 0.75 * min(1, Double(n) / max))
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, col in
                VStack(spacing: 3) {
                    ForEach(col, id: \.self) { day in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(day > Date() ? .clear : shade(day))
                            .frame(width: 11, height: 11)
                            .help("\(Self.fmt.string(from: day)): \(days[Self.fmt.string(from: day)] ?? 0) \(T("words"))")
                    }
                }
            }
        }
    }
}

struct AccountView: View {
    @ObservedObject var store = StatStore.shared
    @ObservedObject var s = Settings.shared

    var name: String { NSFullUserName() }
    var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init)
            .joined().uppercased()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                card { Heatmap(days: store.stat.days) }

                card {
                    VStack(spacing: 0) {
                        HStack(spacing: 14) {
                            Circle().fill(Color.accentColor.opacity(0.8))
                                .frame(width: 52, height: 52)
                                .overlay(Text(initials).font(.title3.weight(.medium))
                                    .foregroundStyle(.white))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name).font(.title3.weight(.medium))
                                Text(NSUserName() + " · " + T("this Mac")).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(T("Sign in")) {}
                                .disabled(true)
                                .help(T("Accounts aren't supported — VoiceKey has no server to sign into."))
                        }
                        .padding(.bottom, 16)

                        Divider()

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(T("Local Plan")).font(.title3.weight(.medium))
                                Text(T("Unlimited words. Audio never leaves this Mac."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(store.stat.words) \(T("words"))")
                                Text((s.cfg.model as NSString).lastPathComponent)
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 16)
                    }
                }
            }
            .padding(24)
        }
    }

    func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}
