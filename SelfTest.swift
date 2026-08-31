import Cocoa
import AVFoundation

/// Run with: ./VoiceKey.app/Contents/MacOS/VoiceKey --selftest
/// Covers the two bits of real logic: transcript cleanup and history trimming.
func runSelfTest() -> Never {
    // Redirect history to a scratch dir BEFORE anything touches History.shared,
    // otherwise the test wipes the user's real recordings.
    setenv("VOICEKEY_HOME", NSTemporaryDirectory() + "voicekey-selftest", 1)

    func check(_ ok: Bool, _ what: String) {
        print(ok ? "ok   \(what)" : "FAIL \(what)")
        if !ok { exit(1) }
    }

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
