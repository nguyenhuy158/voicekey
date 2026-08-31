import Cocoa
import AVFoundation
import SwiftUI

func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok   \(what)" : "FAIL \(what)")
    if !ok { exit(1) }
}

/// Run with: ./VoiceKey.app/Contents/MacOS/VoiceKey --selftest
/// Covers the two bits of real logic: transcript cleanup and history trimming.
func runSelfTest() -> Never {
    // Redirect history to a scratch dir BEFORE anything touches History.shared,
    // otherwise the test wipes the user's real recordings.
    setenv("VOICEKEY_HOME", NSTemporaryDirectory() + "voicekey-selftest", 1)

    check(cleanTranscript("\n Hello Robert, this is a test.\n") == "Hello Robert, this is a test.",
          "trims whitespace and leading newline")
    check(cleanTranscript("[BLANK_AUDIO]") == "", "drops blank-audio marker")
    check(cleanTranscript("(silence)\n[MUSIC]\n") == "", "drops marker-only lines")
    check(cleanTranscript("a\n[BLANK_AUDIO]\nb") == "a b", "joins lines, drops markers between")
    check(cleanTranscript("I said (quietly) no") == "I said (quietly) no",
          "keeps parentheses inside a real sentence")
    check(cleanTranscript("") == "", "empty input stays empty")

    // a config file written before a setting existed must still load (it used to reset)
    let old = #"{"keyCode":54,"keyName":"right \#u{2318}","language":"en","model":"/m.bin"}"#
    let c = try! JSONDecoder().decode(Config.self, from: Data(old.utf8))
    check(c.model == "/m.bin" && c.keyCode == 54, "old config keeps its values")
    check(c.language2 == "vi" && c.playSounds, "missing keys fall back to defaults")

    check(c.streaming == "never" && !c.deepContext && !c.selectToEdit && c.micUID.isEmpty,
          "new settings default off in an old config file")
    check((try? aiEdit(selection: "a", instruction: "b", model: "x")) == nil,
          "aiEdit without a key throws instead of eating the selection")
    check("".nilIfEmpty == nil && "x".nilIfEmpty == "x", "nilIfEmpty")

    // app-specific modes: loose name match, editor wins over browser for "Code"
    check(appMode("iTerm2")?.name == "Terminal", "iTerm is a terminal")
    check(appMode("Cursor")?.name == "Editor", "Cursor is an editor")
    check(appMode("Visual Studio Code")?.name == "Editor", "VS Code is an editor, not a browser")
    check(appMode("Slack")?.name == "Chat", "Slack is chat")
    check(appMode("ChatGPT")?.name == "Prompt", "ChatGPT gets the prompt mode")
    check(appMode("Google Chrome")?.name == "Browser", "Chrome is a browser")
    check(appMode("Preview") == nil && appMode(nil) == nil, "unknown apps have no mode")
    check(!c.appModesEnabled, "app modes default off in an old config file")

    // double-tap latch: tap → discard, quick second tap → latch, next tap → transcribe
    check(tapAction(latched: false, enabled: true, held: 0.1, sinceLastTap: nil) == .discard,
          "a lone short tap is thrown away")
    check(tapAction(latched: false, enabled: true, held: 0.1, sinceLastTap: 0.2) == .latch,
          "a second tap inside the gap latches recording on")
    check(tapAction(latched: false, enabled: true, held: 0.1, sinceLastTap: 1.0) == .discard,
          "a slow second tap doesn't latch")
    check(tapAction(latched: true, enabled: true, held: 0.1, sinceLastTap: 0.2) == .transcribe,
          "tapping a latched key finishes the clip")
    check(tapAction(latched: false, enabled: true, held: 2.0, sinceLastTap: 0.2) == .transcribe,
          "a real hold still transcribes, even right after a tap")
    check(tapAction(latched: false, enabled: false, held: 0.1, sinceLastTap: 0.2) == .transcribe,
          "with latching off every release transcribes")

    // the streaming card shows the newest line first and forgets the rest
    let st = Stream.shared
    for i in 0..<5 { st.push("line \(i)") }
    check(st.lines == ["line 4", "line 3", "line 2"], "stream card keeps the 3 newest, newest first")
    st.clear()
    check(st.lines.isEmpty && !st.busy, "stream clears between clips")

    // the in-app installer has to find tools without the user's PATH
    check(Installer.find("env") == "/usr/bin/env", "find locates a tool in the standard prefixes")
    check(Installer.find("definitely-not-a-real-tool") == nil, "find returns nil for a missing tool")

    check(isCasualApp("Slack") && isCasualApp("Discord Canary") && !isCasualApp("Xcode")
          && !isCasualApp(nil), "casual apps matched by name, case-insensitively")

    // Each entry needs a usable UID. The list itself may be empty — CI runners
    // have no audio hardware — so only well-formedness is asserted here.
    check(Audio.inputs().allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty },
          "input devices enumerate with uid and name")

    check(comboName(9,CGEventFlags([.maskCommand, .maskControl]).rawValue) == "⌃⌘V",
          "combo renders modifiers in Apple's order")

    check(shortDuration(45) == "45s" && shortDuration(511) == "8m 31s"
          && shortDuration(3700) == "1h 1m", "duration formats by magnitude")

    // the AI step must never be able to lose the user's words
    check((try? aiClean("hello", model: "x", prompt: "y")) == nil, "aiClean without a key throws")

    // config round-trips through disk (configURL is redirected by VOICEKEY_HOME)
    try? FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
    var w = Config()
    w.model = "/round/trip.bin"
    w.uiLanguage = "vi"
    w.save()
    check(Config.load().model == "/round/trip.bin", "config survives save and load")
    try? FileManager.default.removeItem(at: configURL)
    check(Config.load().model == Config().model, "a missing config file falls back to defaults")

    check(w.lang(for: w.keyCode) == w.language && w.lang(for: w.keyCode2) == w.language2
          && w.lang(for: -1) == nil, "each talk key maps to its own language")

    check(comboName(9999, 0) == "key 9999", "an unknown key code still renders")

    // UI language: explicit wins over the system, unknown strings pass through
    let saved = Settings.shared.cfg.uiLanguage
    Settings.shared.cfg.uiLanguage = "vi"
    check(uiLang() == "vi" && T("Settings") == "Cài đặt", "vi picks the translation")
    check(T("not a translated string") == "not a translated string", "untranslated text passes through")
    Settings.shared.cfg.uiLanguage = "en"
    check(uiLang() == "en" && T("Settings") == "Settings", "en keeps the English key")
    Settings.shared.cfg.uiLanguage = "system"
    check(["en", "vi"].contains(uiLang()), "system resolves to a real language")
    Settings.shared.cfg.uiLanguage = saved

    check(Audio.device(uid: "no-such-device") == nil, "an unknown mic uid resolves to nil")
    if let first = Audio.inputs().first {
        check(Audio.device(uid: first.uid) == first.id, "a known mic uid resolves to its device")
    }

    // the log truncates itself instead of growing forever
    try? Data(repeating: 0x41, count: 1_100_000).write(to: logURL)
    log("selftest")
    var size = 1_100_000
    for _ in 0..<50 where size > 1_000_000 {
        usleep(20_000)
        size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) as? Int ?? 0
    }
    check(size < 1_000_000, "the log is truncated once it passes 1MB")

    // history trimming keeps the newest entries
    let h = History.shared
    h.clear()
    check(h.entries.isEmpty, "history starts empty after clear")
    for i in 0..<(historyLimit + 5) {
        h.add(audio: historyDir.appendingPathComponent("test-\(i).wav"), text: "line \(i)")
    }
    check(h.entries.count == historyLimit, "history capped at \(historyLimit)")
    check(h.entries.first?.text == "line \(historyLimit + 4)", "newest entry is first")
    check(h.entries.last?.text == "line 5", "oldest entries dropped")
    h.clear()

    MainActor.assumeIsolated { exerciseServices(); exerciseCore(); renderEveryScreen() }

    print("all passed")
    exit(0)
}

/// Run with: ./VoiceKey.app/Contents/MacOS/VoiceKey --checkperms
func runPermCheck() -> Never {
    func line(_ ok: Bool, _ what: String, _ fix: String = "") {
        print("\(ok ? "✅" : "❌")  \(what)\(ok || fix.isEmpty ? "" : "\n      → \(fix)")")
    }

    let mic = AVCaptureDevice.authorizationStatus(for: .audio)
    line(mic == .authorized, "Microphone (\(mic.rawValue == 3 ? "authorized" : "\(mic)"))",
         "System Settings → Privacy & Security → Microphone → enable VoiceKey")

    let ax = AXIsProcessTrusted()
    line(ax, "Accessibility trust",
         "System Settings → Privacy & Security → Accessibility → enable VoiceKey")

    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
    let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                callback: { _, _, e, _ in Unmanaged.passUnretained(e) },
                                userInfo: nil)
    line(tap != nil, "Key event tap (this is what actually matters)",
         "tccutil reset Accessibility local.voicekey, then relaunch and Allow")

    let cfg = Config.load()
    line(FileManager.default.fileExists(atPath: cfg.whisper), "whisper-cli at \(cfg.whisper)",
         "brew install whisper-cpp")
    line(FileManager.default.fileExists(atPath: cfg.model),
         "model \((cfg.model as NSString).lastPathComponent)", "./setup.sh small")
    print("\nhold \(cfg.keyName) → \(cfg.language)   ·   hold \(cfg.keyName2) → \(cfg.language2)")
    exit(0)
}

/// Draws every screen once, offscreen. It asserts nothing about pixels: it is here
/// so a view that crashes on empty data, a nil model or a missing file fails the
/// build instead of the user's first launch.
@MainActor func renderEveryScreen() {
    _ = NSApplication.shared
    @MainActor func render<V: View>(_ name: String, _ v: V) {
        let r = ImageRenderer(content: v.frame(width: 820, height: 620))
        print(r.nsImage == nil ? "FAIL render \(name)" : "ok   render \(name)")
        if r.nsImage == nil { exit(1) }
    }
    render("main", MainView())
    render("settings", SettingsView())
    render("stats", StatsView())
    render("account", AccountView())
    render("history", HistoryView())
    render("build stamp", BuildStamp())
    render("stream card", StreamCard())
    for s in [HUDState.idle, .listening, .transcribing, .streaming] {
        render("hud \(s)", HUDView(state: s, lang: "en"))
    }
}

/// The parts of the app that are objects rather than pure functions: the menu bar
/// app, the HUD panel, the history store, the installer. Nothing here touches the
/// mic, the event tap or the network — those need a real session, and a test that
/// faked them would only be testing the fake.
@MainActor func exerciseServices() {
    _ = NSApplication.shared

    // HUD: every state opens the panel, hide closes it
    for s in [HUDState.idle, .listening, .transcribing, .streaming] {
        HUD.shared.show(s, lang: "en")
    }
    HUD.shared.hide()
    Meter.shared.push(0.5); Meter.shared.reset()
    check(Meter.shared.samples.allSatisfy { $0 == 0 }, "the meter resets to silence")

    // history: add, play a file that isn't there, delete, clear
    let h = History.shared
    h.clear()
    let wav = historyDir.appendingPathComponent("smoke.wav")
    try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
    try? Data("not audio".utf8).write(to: wav)
    h.add(audio: wav, text: "smoke")
    guard let e = h.entries.first else { return check(false, "history kept the entry") }
    check(h.url(e).lastPathComponent == e.audio, "an entry resolves to its file")
    h.toggle(e)                      // not a real wav: must fail without crashing
    check(h.playing == nil, "unplayable audio leaves nothing playing")
    h.stop()
    h.delete(e)
    check(h.entries.isEmpty, "deleting the last entry empties history")

    // installer: cancel is safe with nothing running, and find works both ways
    let i = Installer.shared
    i.cancel()
    check(!i.busy && i.progress == 0, "cancel leaves the installer idle")
    check(downloadableModels.contains { $0.name == "large-v3-turbo-q5_0" },
          "the default model is offered by the installer")

    // the menu bar app, minus applicationDidFinishLaunching (that wants the event tap)
    let a = App()
    a.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    a.buildMainMenu()
    a.buildMenu()
    a.setIcon("mic")

    Settings.shared.capture(1, code: 49, flags: [])
    check(Settings.shared.cfg.keyCode == 49 && Settings.shared.capturingSlot == 0,
          "capturing a key binds it and closes the slot")
    Settings.shared.capture(2, code: 53, flags: [])
    check(Settings.shared.cfg.keyCode2 != 53, "escape cancels the capture")
}

// MARK: the core, on fakes

final class FakeAudio: AudioPort {
    var isRecording = false
    var onChunk: ((URL) -> Void)?
    var failStart = false
    /// Written for real, so the code under test can delete and measure it.
    var wav: URL?
    func start() throws {
        if failStart { throw NSError(domain: "test", code: 1) }
        let u = historyRoot.appendingPathComponent("clip-\(UUID().uuidString).wav")
        try Data(count: 64).write(to: u)
        wav = u
        isRecording = true
    }
    func stop() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        return wav
    }
}

struct FakeSTT: TranscribePort {
    var text = "hello there"
    var error: Error?
    func transcribe(_ wav: URL, lang: String, context: String?) throws -> String {
        if let error { throw error }
        return text
    }
}

final class FakeText: TextPort {
    var typed: [String] = []
    var app: String? = "Slack"
    func type(_ text: String, conceal: Bool) { typed.append(text) }
    func selection() -> String? { nil }
    func context() -> String? { "context" }
    func frontApp() -> String? { app }
}

struct FakeAI: AIPort {
    func clean(_ text: String, model: String, prompt: String) throws -> String { text }
    func edit(selection: String, instruction: String, model: String) throws -> String { instruction }
}

final class FakeUI: FeedbackPort {
    var icons: [String] = []
    var alerts: [(String, String)] = []
    func icon(_ symbol: String) { icons.append(symbol) }
    func hud(_ state: HUDState, lang: String) {}
    func hideHUD() {}
    func sound(_ name: String) {}
    func alert(_ title: String, _ message: String) { alerts.append((title, message)) }
}

final class FakeStore: StorePort {
    var kept: [String] = []
    var words = 0
    func keep(audio: URL, text: String) { kept.append(text) }
    func record(words n: Int, seconds: Double, app: String?) { words += n }
}

/// endTalk hops to streamQueue and back to main; with no NSApp running, the main
/// queue only drains while the run loop turns. Pump it until `done` or we give up.
func pump(_ seconds: Double = 3, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}

/// A real, readable wav — enough for AVAudioFile to report a length.
func makeWav(seconds: Double) -> URL {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                            channels: 1, interleaved: true)!
    let u = historyRoot.appendingPathComponent("dur-\(UUID().uuidString).wav")
    let f = try! AVAudioFile(forWriting: u, settings: fmt.settings,
                             commonFormat: .pcmFormatInt16, interleaved: true)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(16000 * seconds))!
    buf.frameLength = buf.frameCapacity
    try! f.write(from: buf)
    return u
}

@MainActor func exerciseCore() {
    let wavURL = makeWav(seconds: 1)
    check(abs(duration(wavURL) - 1) < 0.01, "a wav reports its length in seconds")
    check(duration(historyRoot.appendingPathComponent("nope.wav")) == 0,
          "an unreadable wav measures zero instead of crashing")

    let audio = FakeAudio(), text = FakeText(), ui = FakeUI(), store = FakeStore()
    func make(_ stt: FakeSTT = FakeSTT()) -> Dictation {
        Dictation(audio: audio, stt: stt, text: text, ai: FakeAI(), ui: ui, store: store)
    }
    var d = make()

    d.targetApp = "Slack"
    Settings.shared.cfg.casualMessaging = true
    check(d.casual("Hello There") == "hello there", "chat apps get lowercase text")
    Settings.shared.cfg.casualMessaging = false
    check(d.casual("Hello There") == "Hello There", "everywhere else keeps the case")
    Settings.shared.cfg.appModesEnabled = true
    check(d.promptForApp().hasSuffix(appMode("Slack")!.hint), "the app mode is appended to the prompt")
    Settings.shared.cfg.appModesEnabled = false
    check(d.promptForApp() == d.cfg.aiPrompt, "with modes off the prompt is untouched")

    // a release with no press behind it must not leave state around
    d.keyReleased(d.cfg.keyCode, "en")
    d.cancelTalk(silent: true)
    check(d.latchedCode == nil && d.pressedAt == nil, "cancel clears the latch")

    // a whole clip, end to end
    Settings.shared.cfg.privacyMode = false
    Settings.shared.cfg.aiEnabled = false
    Settings.shared.cfg.streaming = "off"
    d.beginTalk("en")
    check(audio.isRecording && d.targetApp == "Slack", "begin records and pins the target app")
    d.endTalk("en")
    pump { !text.typed.isEmpty }
    check(text.typed == ["hello there"], "the transcript is typed once")
    check(store.kept == ["hello there"] && store.words == 2, "it lands in history and stats")
    check(d.lastTranscript == "hello there", "and is remembered for paste-last")
    text.typed = []
    d.pasteLast()
    check(text.typed == ["hello there"], "paste-last retypes it without recording")

    // privacy mode: the audio goes, nothing is kept
    Settings.shared.cfg.privacyMode = true
    store.kept = []; text.typed = []
    d.beginTalk("en")
    let wav = audio.wav!
    d.endTalk("en")
    pump { !text.typed.isEmpty }
    check(store.kept.isEmpty, "privacy mode keeps no history")
    check(!FileManager.default.fileExists(atPath: wav.path), "and deletes the recording")
    Settings.shared.cfg.privacyMode = false

    // a chunk that finishes after its clip was cancelled must not paste
    d.beginTalk("en")
    let stale = d.clipID
    d.cancelTalk(silent: true)
    text.typed = []
    d.streamChunk(audio.wav!, "en", stale)
    pump(0.5) { !text.typed.isEmpty }
    check(text.typed.isEmpty, "a chunk from a dead clip is dropped")

    // failures reach the user instead of pasting nonsense
    d = make(FakeSTT(error: TranscribeError.modelMissing("/nope/model.bin")))
    ui.alerts = []; text.typed = []
    d.beginTalk("en"); d.endTalk("en")
    pump { !ui.alerts.isEmpty }
    check(ui.alerts.first?.1.contains("/nope/model.bin") == true, "a missing model names the path")
    check(text.typed.isEmpty, "and nothing is typed")
    check(d.explain(TranscribeError.toolMissing("/nope/whisper")).1.contains("whisper-cpp"),
          "a missing whisper-cli names the brew formula")

    audio.failStart = true
    ui.icons = []
    d.beginTalk("en")
    check(ui.icons.last == "exclamationmark.triangle", "a mic that won't start shows the warning icon")
    audio.failStart = false
}
