import SwiftUI
import ServiceManagement

/// Single source of truth for Config, so the menu bar and the settings window
/// never drift apart. App mutates it too (key capture happens in the event tap).
final class Settings: ObservableObject {
    static let shared = Settings()
    @Published var cfg = Config.load()
    @Published var capturingSlot = 0        // 0 = idle, else the key slot being rebound
    var onChange: (() -> Void)?

    private init() {}

    func save() {
        cfg.save()
        onChange?()
    }

    /// Login-item state lives in launchd, not our config file.
    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register()
                          : try SMAppService.mainApp.unregister() }
            catch { NSLog("login item: \(error.localizedDescription)") }
            objectWillChange.send()
        }
    }
}

/// whisper's language codes — "auto" lets it guess, which is what breaks
/// code-switching (see ISSUES.md), hence one pinned language per key.
let languages: [(String, String)] = [
    ("auto", "Auto-detect"), ("en", "English"), ("vi", "Tiếng Việt"),
    ("ja", "日本語"), ("ko", "한국어"), ("zh", "中文"), ("fr", "Français"),
    ("de", "Deutsch"), ("es", "Español"), ("th", "ไทย"),
]

/// One row of the System section: icon, toggle, title, explanation.
struct ToggleRow: View {
    let icon: String, title: String, note: String
    @Binding var on: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            Toggle("", isOn: $on).labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct KeyRow: View {
    let title: String
    let slot: Int
    @ObservedObject var s = Settings.shared

    var keyName: String { slot == 1 ? s.cfg.keyName : s.cfg.keyName2 }
    var capturing: Bool { s.capturingSlot == slot }

    var langBinding: Binding<String> {
        slot == 1 ? Binding(get: { s.cfg.language }, set: { s.cfg.language = $0; s.save() })
                  : Binding(get: { s.cfg.language2 }, set: { s.cfg.language2 = $0; s.save() })
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 60, alignment: .leading)

            Button { s.capturingSlot = capturing ? 0 : slot } label: {
                Text(capturing ? T("Press a key…") : keyName)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 110)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(capturing ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(T("Click, then hold the key you want to use"))

            Image(systemName: "arrow.right").foregroundStyle(.secondary)

            Picker("", selection: langBinding) {
                ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .frame(width: 150)
        }
    }
}

/// A keybinding with no language attached (hands-free, paste-last).
struct BindRow: View {
    let icon: String, title: String, note: String, slot: Int
    let label: String
    var onClear: (() -> Void)? = nil
    @ObservedObject var s = Settings.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { s.capturingSlot = s.capturingSlot == slot ? 0 : slot } label: {
                Text(s.capturingSlot == slot ? T("Press…") : label)
                    .font(.system(size: 12, weight: .medium))
                    .frame(minWidth: 80)
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(s.capturingSlot == slot ? Color.accentColor.opacity(0.25)
                                                      : Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            if let onClear {
                Button { onClear() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(T("Unbind"))
            }
        }
        .padding(.vertical, 2)
    }
}

struct SettingsView: View {
    @ObservedObject var s = Settings.shared

    /// Whatever ggml-*.bin the user has downloaded, plus whatever is configured.
    var models: [String] {
        let dir = configDir.appendingPathComponent("models")
        let found = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasSuffix(".bin") }
            .map { dir.appendingPathComponent($0).path } ?? []
        return Array(Set(found + [s.cfg.model])).sorted()
    }

    @State private var apiKey = Keychain.get()
    @State private var testing = false
    @State private var testResult = ""

    func bindStr(_ path: WritableKeyPath<Config, String>) -> Binding<String> {
        Binding(get: { s.cfg[keyPath: path] }, set: { s.cfg[keyPath: path] = $0; s.save() })
    }

    /// Round-trips one messy sentence so a bad key or dead model shows up here,
    /// not silently mid-dictation.
    func test() {
        testing = true; testResult = ""
        let (model, prompt) = (s.cfg.aiModel, s.cfg.aiPrompt)
        DispatchQueue.global().async {
            let r: String
            do { r = "✅ " + (try aiClean("toi can fix cai bug nay trong file main swift",
                                          model: model, prompt: prompt)) }
            catch { r = "❌ " + error.localizedDescription }
            DispatchQueue.main.async { testResult = r; testing = false }
        }
    }

    /// Every Config toggle saves the moment it flips — no Apply button to forget.
    func bind(_ path: WritableKeyPath<Config, Bool>) -> Binding<Bool> {
        Binding(get: { s.cfg[keyPath: path] }, set: { s.cfg[keyPath: path] = $0; s.save() })
    }

    var body: some View {
        Form {
            Section(T("Hold to talk")) {
                KeyRow(title: T("Key 1"), slot: 1)
                KeyRow(title: T("Key 2"), slot: 2)
                Text(T("Each key is pinned to one language — whisper can't reliably mix two in one sentence."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(T("Keybindings")) {
                BindRow(icon: "hand.raised", title: T("Activate Hands Free"),
                        note: "\(T("Tap once to start, tap again to stop. Uses")) \(s.cfg.language).",
                        slot: 3, label: s.cfg.handsFreeName,
                        onClear: s.cfg.handsFreeKey < 0 ? nil : {
                            s.cfg.handsFreeKey = -1; s.cfg.handsFreeName = "none"; s.save()
                        })
                BindRow(icon: "doc.on.clipboard", title: T("Paste Last Transcript"),
                        note: T("Paste the previous result again, without re-recording."),
                        slot: 4, label: comboName(s.cfg.pasteLastKey, s.cfg.pasteLastFlags))
                ToggleRow(icon: "hand.tap", title: T("Double-Tap to Latch"),
                          note: T("Double-tap a talk key to keep recording hands-free; tap once more to finish."),
                          on: bind(\.doubleTapLatch))
                ToggleRow(icon: "xmark.circle", title: T("Cancel with Escape"),
                          note: T("Throw away the clip in progress — nothing is transcribed or pasted."),
                          on: bind(\.cancelWithEscape))
            }

            Section(T("Model")) {
                Picker(T("Whisper model"), selection: Binding(
                    get: { s.cfg.model }, set: { s.cfg.model = $0; s.save() })) {
                    ForEach(models, id: \.self) {
                        Text(($0 as NSString).lastPathComponent).tag($0)
                    }
                }
                if !FileManager.default.fileExists(atPath: s.cfg.model) {
                    Label(T("Model file is missing — run ./setup.sh"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("whisper-cli").frame(width: 90, alignment: .leading)
                    TextField("", text: Binding(
                        get: { s.cfg.whisper }, set: { s.cfg.whisper = $0; s.save() }))
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: FileManager.default.fileExists(atPath: s.cfg.whisper)
                          ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(FileManager.default.fileExists(atPath: s.cfg.whisper)
                                         ? Color.green : Color.red)
                }
            }

            Section(T("System")) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "globe").frame(width: 20).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("Interface Language"))
                        Text(T("Language of the VoiceKey window and menus."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Picker("", selection: Binding(
                        get: { s.cfg.uiLanguage },
                        set: { s.cfg.uiLanguage = $0; s.save() })) {
                        ForEach(uiLanguages, id: \.0) { Text(T($0.1)).tag($0.0) }
                    }
                    .labelsHidden().frame(width: 130)
                }
                .padding(.vertical, 2)

                ToggleRow(icon: "rectangle.bottomthird.inset.filled",
                          title: T("Show Floating Bar"),
                          note: T("Always show the bar at the bottom of your screen."),
                          on: bind(\.floatingBar))
                ToggleRow(icon: "speaker.wave.2", title: T("Play Sounds"),
                          note: T("A tick when recording starts, a pop when the text lands."),
                          on: bind(\.playSounds))
                ToggleRow(icon: "clipboard", title: T("Avoid Clipboard History"),
                          note: T("Marks the paste as concealed so clipboard managers skip it."),
                          on: bind(\.avoidClipboardHistory))
                ToggleRow(icon: "shield", title: T("Privacy Mode"),
                          note: T("Don't keep the audio or the transcript in History."),
                          on: bind(\.privacyMode))
                ToggleRow(icon: "arrow.counterclockwise", title: T("Open at Login"),
                          note: T("Start VoiceKey when your computer starts."),
                          on: Binding(get: { s.openAtLogin }, set: { s.openAtLogin = $0 }))

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock").frame(width: 20).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("Accessibility Permission"))
                        Text(T("Required. Used to read the hold-key and paste the text."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if AXIsProcessTrusted() {
                        Label(T("Granted"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).labelStyle(.iconOnly).font(.title3)
                    } else {
                        Button(T("Grant…")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                Button(T("Reset to Defaults")) {
                    let keep = (s.cfg.model, s.cfg.whisper)
                    s.cfg = Config()
                    (s.cfg.model, s.cfg.whisper) = keep
                    s.save()
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 360)
        .onDisappear { Settings.shared.capturingSlot = 0 }
    }
}
