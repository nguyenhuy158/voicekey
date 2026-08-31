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
            .pickerStyle(.menu)
            .frame(width: 200)
        }
    }
}

/// A label (+ optional icon/note) with a full-width dropdown underneath.
/// Built from Menu, not Picker: the stock macOS pop-up bezel shrinks to its
/// content and reads as invisible inside a grouped Form.
struct DropRow: View {
    var icon: String? = nil
    let title: String
    var note: String? = nil
    /// (value, display label) — order is the menu order.
    let options: [(String, String)]
    @Binding var selection: String
    var enabled = true

    private var currentLabel: String {
        options.first { $0.0 == selection }?.1 ?? selection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                if let icon { Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Menu {
                ForEach(options, id: \.0) { opt in
                    Button {
                        selection = opt.0
                    } label: {
                        if opt.0 == selection { Label(opt.1, systemImage: "checkmark") }
                        else { Text(opt.1) }
                    }
                }
            } label: {
                HStack {
                    Text(currentLabel).lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
        .padding(.vertical, 2)
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

    /// Auto-detect can change language between chunks, so a key set to Auto never
    /// streams — but the other key still can, so this is per-key, not global.
    var streamingNote: String {
        let auto = [s.cfg.language, s.cfg.language2].contains("auto")
        return T("Type each sentence as you pause, instead of all of it on release.")
            + (auto ? " " + T("Keys set to Auto-detect stay non-streaming.") : "")
    }

    @State private var mics = Audio.inputs()
    @State private var micTest = false
    @State private var testRec = Recorder()
    @State private var testSound: NSSound?

    /// Records a couple of seconds off the selected device and plays it straight back,
    /// so a dead or wrong mic is obvious before you dictate into it.
    func startMicTest() {
        do { try testRec.start() } catch { return }
        micTest = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if micTest { stopMicTest() }
        }
    }

    func stopMicTest() {
        micTest = false
        guard let wav = testRec.stop() else { return }
        testSound = NSSound(contentsOf: wav, byReference: false)
        testSound?.play()
        // Keep it out of History and off disk; the playback holds its own copy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            try? FileManager.default.removeItem(at: wav)
        }
    }

    @State private var apiKey = Keychain.get()
    @State private var testing = false
    @State private var testResult = ""
    @State private var models_ai = freeModels

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
            Section(T("Microphone")) {
                HStack(spacing: 8) {
                    Image(systemName: "mic").frame(width: 20).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { s.cfg.micUID }, set: { s.cfg.micUID = $0; s.save() })) {
                        Text(T("Default")).tag("")
                        ForEach(mics) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Button {
                        micTest ? stopMicTest() : startMicTest()
                    } label: {
                        Label(micTest ? T("Stop") : T("Test"), systemImage: "speaker.wave.2")
                    }
                    Button { mics = Audio.inputs() } label: { Image(systemName: "arrow.clockwise") }
                        .help(T("Rescan devices"))
                }
                if micTest {
                    Text(T("Recording 2s — it plays back when it stops."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

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
                DropRow(title: T("Whisper model"),
                        options: models.map { ($0, ($0 as NSString).lastPathComponent) },
                        selection: bindStr(\.model))
                if !FileManager.default.fileExists(atPath: s.cfg.model) {
                    Label(T("Model file is missing — use Install Engine & Model above."),
                          systemImage: "exclamationmark.triangle")
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
                DropRow(icon: "globe", title: T("Interface Language"),
                        note: T("Language of the VoiceKey window and menus."),
                        options: uiLanguages.map { ($0.0, T($0.1)) },
                        selection: bindStr(\.uiLanguage))

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
                ToggleRow(icon: "brain", title: T("Deep Context"),
                          note: T("Use text from the field you're typing into to boost accuracy. Context stays on your Mac and is not stored."),
                          on: bind(\.deepContext))
                ToggleRow(icon: "square.and.pencil", title: T("Select to Edit"),
                          note: "\(T("Select text, hold")) \(s.cfg.keyName), \(T("then say the change to edit it in place. Needs an API key."))",
                          on: bind(\.selectToEdit))

                DropRow(icon: "water.waves", title: T("Streaming Mode"), note: streamingNote,
                        options: [("never", T("Never")), ("auto", T("Auto"))],
                        selection: bindStr(\.streaming),
                        enabled: [s.cfg.language, s.cfg.language2] != ["auto", "auto"])

                ToggleRow(icon: "bubble.left", title: T("Casual Messaging"),
                          note: T("Use lowercase text in chat apps like Slack, iMessage, Discord."),
                          on: bind(\.casualMessaging))
                ToggleRow(icon: "app.badge", title: T("App-Specific Modes"),
                          note: T("Adapt AI Cleanup to the app: shell commands in Terminal, code terms in Cursor/VS Code, short messages in Slack, prompts in ChatGPT. Needs AI Cleanup on."),
                          on: bind(\.appModesEnabled))
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

            Section(T("AI Cleanup")) {
                ToggleRow(icon: "sparkles", title: T("AI Cleanup"),
                          note: T("Send the transcript to OpenRouter to fix punctuation and typos. Off while Privacy Mode is on."),
                          on: bind(\.aiEnabled))

                HStack {
                    Text(T("API key")).frame(width: 90, alignment: .leading)
                    SecureField("sk-or-v1-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Keychain.set(apiKey) }
                    Button(T("Save")) { Keychain.set(apiKey) }
                }
                Link(T("Get a free key at openrouter.ai"),
                     destination: URL(string: "https://openrouter.ai/keys")!)
                    .font(.caption)

                // The saved model may have been retired — keep it listed.
                DropRow(title: T("Model"),
                        options: (models_ai.contains(s.cfg.aiModel) ? models_ai : [s.cfg.aiModel] + models_ai)
                            .map { ($0, $0) },
                        selection: bindStr(\.aiModel))

                HStack {
                    Button(T("Test")) { Keychain.set(apiKey); test() }
                        .disabled(testing || apiKey.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    Text(testResult).font(.caption).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        .onAppear { fetchFreeModels { models_ai = $0 } }
        .onDisappear { Settings.shared.capturingSlot = 0 }
    }
}
