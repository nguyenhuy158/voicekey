import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case history, stats, account, settings
    var id: String { rawValue }
    var title: String { T(rawValue.prefix(1).uppercased() + rawValue.dropFirst()) }
    var icon: String {
        switch self {
        case .history:  return "waveform"
        case .stats:    return "chart.bar"
        case .account:  return "person.crop.circle"
        case .settings: return "gearshape"
        }
    }
}

/// Which pane the single main window is showing. Menu items just poke this.
final class Nav: ObservableObject {
    static let shared = Nav()
    @Published var tab: Tab = .history
}

struct MainView: View {
    @ObservedObject var nav = Nav.shared
    @ObservedObject var settings = Settings.shared

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: Binding(
                get: { Optional(nav.tab) }, set: { nav.tab = $0 ?? .history })) { tab in
                Label(tab.title, systemImage: tab.icon).tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            switch nav.tab {
            case .history:  HistoryView()
            case .stats:    StatsView()
            case .account:  AccountView()
            case .settings: SettingsView()
            }
        }
        .navigationTitle(nav.tab.title)
        .id(settings.cfg.uiLanguage)   // rebuild the whole tree when the language flips
    }
}

final class MainWindow {
    static var window: NSWindow?

    static func show(_ tab: Tab? = nil) {
        if let tab { Nav.shared.tab = tab }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                         .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.contentView = NSHostingView(rootView: MainView())
            w.setFrameAutosaveName("VoiceKeyMain")
            w.center()
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
