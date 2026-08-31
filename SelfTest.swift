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

    check(comboName(9, CGEventFlags([.maskCommand, .maskControl]).rawValue) == "⌃⌘V",
          "combo renders modifiers in Apple's order")

    check(shortDuration(45) == "45s" && shortDuration(511) == "8m 31s"
          && shortDuration(3700) == "1h 1m", "duration formats by magnitude")

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
