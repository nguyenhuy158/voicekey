import Cocoa
import AVFoundation

// ---------- config ----------

let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/voicekey")
let configURL = configDir.appendingPathComponent("config.json")

struct Config: Codable {
    // Two hold-keys, each pinned to a language — no GUI, edit config.json to change.
    var keyCode: Int64 = 54          // right ⌘
    var keyName: String = "right ⌘"
    var language: String = "en"

    var keyCode2: Int64 = 61         // right ⌥
    var keyName2: String = "right ⌥"
    var language2: String = "vi"

    var model: String = configDir.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin").path
    var whisper: String = "/opt/homebrew/bin/whisper-cli"

    // -1 = unbound. Hands-free taps once to start and once to stop.
    var handsFreeKey: Int64 = -1
    var handsFreeName = "none"
    /// Re-paste the last transcript. Stored as keycode + the modifiers that must be held.
    var pasteLastKey: Int64 = 9                                  // v
    var pasteLastFlags: UInt64 = CGEventFlags([.maskCommand, .maskControl]).rawValue
    var cancelWithEscape = true

    var aiEnabled = false
    var aiModel = freeModels[0]
    var aiPrompt = defaultAIPrompt

    var floatingBar = false
    var playSounds = true
    var avoidClipboardHistory = true
    var privacyMode = false
    /// "system" (follow macOS), "en" or "vi".
    var uiLanguage = "system"

    /// Which slot a keycode belongs to, and the language it speaks.
    func lang(for code: Int64) -> String? {
        code == keyCode ? language : (code == keyCode2 ? language2 : nil)
    }

    /// Synthesized Decodable throws on a missing key even when the property has a
    /// default, so every new setting would wipe the user's existing config file.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        func f<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)) .flatMap { $0 } ?? fallback
        }
        keyCode = f(.keyCode, d.keyCode);   keyName = f(.keyName, d.keyName)
        language = f(.language, d.language)
        keyCode2 = f(.keyCode2, d.keyCode2); keyName2 = f(.keyName2, d.keyName2)
        language2 = f(.language2, d.language2)
        model = f(.model, d.model);         whisper = f(.whisper, d.whisper)
        handsFreeKey = f(.handsFreeKey, d.handsFreeKey)
        handsFreeName = f(.handsFreeName, d.handsFreeName)
        pasteLastKey = f(.pasteLastKey, d.pasteLastKey)
        pasteLastFlags = f(.pasteLastFlags, d.pasteLastFlags)
        cancelWithEscape = f(.cancelWithEscape, d.cancelWithEscape)
        aiEnabled = f(.aiEnabled, d.aiEnabled)
        aiModel = f(.aiModel, d.aiModel)
        aiPrompt = f(.aiPrompt, d.aiPrompt)
        floatingBar = f(.floatingBar, d.floatingBar)
        playSounds = f(.playSounds, d.playSounds)
        avoidClipboardHistory = f(.avoidClipboardHistory, d.avoidClipboardHistory)
        privacyMode = f(.privacyMode, d.privacyMode)
        uiLanguage = f(.uiLanguage, d.uiLanguage)
    }

    static func load() -> Config {
        guard let d = try? Data(contentsOf: configURL),
              let c = try? JSONDecoder().decode(Config.self, from: d) else { return Config() }
        return c
    }
    func save() {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = .prettyPrinted
        try? e.encode(self).write(to: configURL)
    }
}

// Modifier keycode -> the flag that means "held". Absent = a normal key.
let modifierFlags: [Int64: CGEventFlags] = [
    54: .maskCommand, 55: .maskCommand,
    56: .maskShift,   60: .maskShift,
    58: .maskAlternate, 61: .maskAlternate,
    59: .maskControl, 62: .maskControl,
    63: .maskSecondaryFn,
    57: .maskAlphaShift,
]

let keyNames: [Int64: String] = [
    54: "right ⌘", 55: "⌘", 56: "⇧", 60: "right ⇧", 58: "⌥", 61: "right ⌥",
    59: "⌃", 62: "right ⌃", 63: "fn", 57: "caps lock",
    49: "space", 36: "return", 53: "escape",
    0: "A", 1: "S", 2: "D", 8: "C", 9: "V", 11: "B", 15: "R", 17: "T", 35: "P", 40: "K",
]

/// Only these count when matching a shortcut — ignore caps lock, numpad, etc.
let comboMask = CGEventFlags([.maskCommand, .maskControl, .maskAlternate,
                              .maskShift, .maskSecondaryFn])

func comboName(_ code: Int64, _ flags: UInt64) -> String {
    let f = CGEventFlags(rawValue: flags)
    var s = ""
    if f.contains(.maskSecondaryFn) { s += "fn" }
    if f.contains(.maskControl) { s += "⌃" }
    if f.contains(.maskAlternate) { s += "⌥" }
    if f.contains(.maskShift) { s += "⇧" }
    if f.contains(.maskCommand) { s += "⌘" }
    return s + (keyNames[code] ?? "key \(code)")
}

// ---------- recorder ----------

final class Recorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var isRecording = false

    private(set) var url = historyDir.appendingPathComponent("voicekey.wav")

    func start() throws {
        guard !isRecording else { return }
        try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        url = historyDir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).wav")
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw NSError(domain: "voicekey", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no audio input device"]) }

        // whisper wants 16 kHz mono
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                      channels: 1, interleaved: true)!
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        file = try AVAudioFile(forWriting: url, settings: outFormat.settings,
                               commonFormat: .pcmFormatInt16, interleaved: true)

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            guard let self, let conv = self.converter, let file = self.file else { return }
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            if err == nil && out.frameLength > 0 { try? file.write(from: out) }

            // drive the HUD waveform
            if let ch = buf.floatChannelData?[0], buf.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
                let rms = (sum / Float(buf.frameLength)).squareRoot()
                DispatchQueue.main.async { Meter.shared.push(rms) }
            }
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops and returns the wav path, or nil if the clip was too short to bother with.
    func stop() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let frames = file?.length ?? 0
        file = nil; converter = nil
        guard frames > 16000 / 5 else {         // < 0.2s = a stray tap, ignore
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }
}

// ---------- transcript cleanup ----------

/// whisper emits marker-only lines like "[BLANK_AUDIO]" or "(silence)" for empty clips.
/// Drops those whole-line markers and joins the rest — a spoken "(like this)" must survive.
func cleanTranscript(_ raw: String) -> String {
    raw.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && $0.range(of: "^(\\[.*\\]|\\(.*\\))$",
                                          options: .regularExpression) == nil }
        .joined(separator: " ")
}

// ---------- text insertion ----------

func typeText(_ text: String, conceal: Bool) {
    let pb = NSPasteboard.general
    let saved = pb.string(forType: .string)
    pb.clearContents()
    pb.setString(text, forType: .string)
    // Clipboard managers honour this marker and skip the item entirely.
    if conceal {
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }

    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // v
    let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)

    // restore the user's clipboard once the paste has landed
    if let saved {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pb.clearContents(); pb.setString(saved, forType: .string)
        }
    }
}

// ---------- app ----------

let debugKeys = CommandLine.arguments.contains("--debug")

final class App: NSObject, NSApplicationDelegate {
    var cfg: Config { Settings.shared.cfg }
    let rec = Recorder()
    var item: NSStatusItem!
    var tap: CFMachPort?
    var heldCode: Int64?         // the key currently held down
    var handsFreeLang: String?   // non-nil while a hands-free clip is running
    var lastTranscript = ""
    var targetApp: String?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("mic")
        buildMenu()
        Settings.shared.onChange = { [weak self] in
            self?.buildMenu()
            self?.buildMainMenu()
            if !(self?.rec.isRecording ?? false) { HUD.shared.hide() }   // apply floating-bar toggle
        }
        buildMainMenu()
        HUD.shared.hide()          // draws the floating bar if it's turned on

        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // Never block launch on a permission alert — ask via the system prompt and
        // keep retrying, so granting it takes effect without relaunching.
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        startTap()
        MainWindow.show(.history)
    }

    func setIcon(_ name: String) {
        item.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "VoiceKey")
    }

    /// A .regular app gets no menu bar for free — without this ⌘Q and ⌘W do nothing.
    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: T("Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: T("Hide VoiceKey"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: T("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: T("Quit VoiceKey"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (t, sel, k) in [("Cut", #selector(NSText.cut(_:)), "x"),
                            ("Copy", #selector(NSText.copy(_:)), "c"),
                            ("Paste", #selector(NSText.paste(_:)), "v"),
                            ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: T(t), action: sel, keyEquivalent: k)
        }
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    func buildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "\(T("Hold")) \(cfg.keyName) → \(cfg.language)", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(withTitle: "\(T("Hold")) \(cfg.keyName2) → \(cfg.language2)", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(.separator())
        m.addItem(withTitle: T("Open VoiceKey"), action: #selector(showHistory), keyEquivalent: "o").target = self
        m.addItem(withTitle: T("Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        m.addItem(.separator())
        m.addItem(withTitle: T("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
    }

    @objc func showHistory() { MainWindow.show(.history) }

    @objc func showSettings() { MainWindow.show(.settings) }

    /// Dock icon click with no window open — bring the main window back.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool {
        if !f { MainWindow.show() }
        return true
    }

    func alert(_ title: String, _ msg: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = msg
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: event tap

    func startTap() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) |
                   (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.keyUp.rawValue)
        guard let t = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, ctx in
                let app = Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue()
                return app.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            // macOS caches the Accessibility verdict per process, so a process that
            // started untrusted stays untrusted — retrying in-process never recovers.
            // Poll until trust appears, then relaunch ourselves to get a fresh verdict.
            setIcon("exclamationmark.triangle")
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
                if AXIsProcessTrusted() { self.relaunch() } else { self.startTap() }
            }
            return
        }
        setIcon("mic")
        tap = t
        if debugKeys { FileHandle.standardError.write("tap created OK\n".data(using: .utf8)!) }
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: cfg) { _, _ in exit(0) }
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if debugKeys {
            FileHandle.standardError.write("tap type=\(type.rawValue) code=\(code) flags=\(event.flags.rawValue) want=\(cfg.keyCode)\n".data(using: .utf8)!)
        }

        let flags = event.flags
        let slot = Settings.shared.capturingSlot
        if slot != 0 {
            guard type == .keyDown || type == .flagsChanged else { return Unmanaged.passUnretained(event) }
            if type == .flagsChanged && modifierFlags[code] == nil { return Unmanaged.passUnretained(event) }
            // A combo needs a real key plus modifiers, so bare modifier taps don't count.
            if slot == 4 && type != .keyDown { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async {
                let s = Settings.shared
                s.capturingSlot = 0
                if code != 53 {   // escape = cancel
                    let name = keyNames[code] ?? "key \(code)"
                    switch slot {
                    case 1: s.cfg.keyCode = code;  s.cfg.keyName = name
                    case 2: s.cfg.keyCode2 = code; s.cfg.keyName2 = name
                    case 3: s.cfg.handsFreeKey = code; s.cfg.handsFreeName = name
                    default:
                        s.cfg.pasteLastKey = code
                        s.cfg.pasteLastFlags = flags.intersection(comboMask).rawValue
                    }
                    s.save()
                }
            }
            return nil
        }

        // Escape aborts the clip in progress — nothing transcribed, nothing pasted.
        if cfg.cancelWithEscape && code == 53 && type == .keyDown && isTalking {
            DispatchQueue.main.async { self.cancelTalk() }
            return nil
        }

        // Paste the last transcript again.
        if type == .keyDown && code == cfg.pasteLastKey && !lastTranscript.isEmpty
            && flags.intersection(comboMask).rawValue == cfg.pasteLastFlags {
            let text = lastTranscript
            DispatchQueue.main.async { typeText(text, conceal: self.cfg.avoidClipboardHistory) }
            return nil
        }

        // Hands free: one tap starts, the next stops.
        if code == cfg.handsFreeKey, heldCode == nil {
            let fire = modifierFlags[code].map { type == .flagsChanged && flags.contains($0) }
                       ?? (type == .keyDown)
            if fire {
                DispatchQueue.main.async {
                    if let lang = self.handsFreeLang { self.handsFreeLang = nil; self.endTalk(lang) }
                    else { self.handsFreeLang = self.cfg.language; self.beginTalk(self.cfg.language) }
                }
                return modifierFlags[code] == nil ? nil : Unmanaged.passUnretained(event)
            }
            if modifierFlags[code] == nil { return nil }   // swallow the key-up too
        }

        guard let lang = cfg.lang(for: code), handsFreeLang == nil else {
            return Unmanaged.passUnretained(event)
        }
        // Ignore the other key while one is already held, so the language can't switch mid-clip.
        guard heldCode == nil || heldCode == code else { return Unmanaged.passUnretained(event) }

        if let flag = modifierFlags[code] {
            guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
            let pressed = event.flags.contains(flag)
            if pressed != (heldCode == code) {
                heldCode = pressed ? code : nil
                DispatchQueue.main.async { pressed ? self.beginTalk(lang) : self.endTalk(lang) }
            }
            return Unmanaged.passUnretained(event)   // don't break the modifier for other apps
        }

        // plain key: swallow it so holding it doesn't spam characters
        if type == .keyDown && heldCode == nil {
            heldCode = code
            DispatchQueue.main.async { self.beginTalk(lang) }
        } else if type == .keyUp {
            heldCode = nil
            DispatchQueue.main.async { self.endTalk(lang) }
        }
        return nil
    }

    // MARK: talk

    var isTalking: Bool { rec.isRecording }

    func cancelTalk() {
        handsFreeLang = nil
        heldCode = nil
        if let wav = rec.stop() { try? FileManager.default.removeItem(at: wav) }
        setIcon("mic")
        HUD.shared.hide()
        if cfg.playSounds { NSSound(named: "Funk")?.play() }
    }

    func beginTalk(_ lang: String) {
        // Grab it now — after we paste, the frontmost app may have changed.
        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
        do {
            try rec.start()
            setIcon("waveform")
            if cfg.playSounds { NSSound(named: "Tink")?.play() }
            Meter.shared.reset()
            HUD.shared.show(.listening, lang: lang)
        } catch {
            setIcon("exclamationmark.triangle")
            HUD.shared.hide()
            NSLog("record failed: \(error.localizedDescription)")
        }
    }

    func endTalk(_ lang: String) {
        guard let wav = rec.stop() else { setIcon("mic"); HUD.shared.hide(); return }
        setIcon("hourglass")
        HUD.shared.show(.transcribing, lang: lang)
        // Measure before Privacy Mode deletes the file out from under us.
        let secs = (try? AVAudioFile(forReading: wav)).map {
            Double($0.length) / $0.fileFormat.sampleRate } ?? 0
        DispatchQueue.global(qos: .userInitiated).async {
            var text = self.transcribe(wav, lang)
            // Privacy Mode means nothing leaves the Mac, so it wins over AI cleanup.
            if self.cfg.aiEnabled && !self.cfg.privacyMode && !text.isEmpty {
                do { text = try aiClean(text, model: self.cfg.aiModel, prompt: self.cfg.aiPrompt) }
                catch { NSLog("ai cleanup skipped: \(error.localizedDescription)") }
            }
            let final = text
            DispatchQueue.main.async {
                self.setIcon("mic")
                HUD.shared.hide()
                if self.cfg.playSounds { NSSound(named: "Pop")?.play() }
                if self.cfg.privacyMode {
                    try? FileManager.default.removeItem(at: wav)
                } else {
                    History.shared.add(audio: wav, text: final)
                }
                guard !final.isEmpty else { return }
                StatStore.shared.record(words: final.split(separator: " ").count,
                                        seconds: secs, app: self.targetApp)
                self.lastTranscript = final
                typeText(final, conceal: self.cfg.avoidClipboardHistory)
            }
        }
    }

    func transcribe(_ wav: URL, _ lang: String) -> String {
        guard FileManager.default.fileExists(atPath: cfg.model) else {
            DispatchQueue.main.async {
                self.alert(T("Model missing"), uiLang() == "vi"
                    ? "Chạy ./setup.sh để tải mô hình whisper.\n\nĐường dẫn mong đợi:\n\(self.cfg.model)"
                    : "Run ./setup.sh to download the whisper model.\n\nExpected at:\n\(self.cfg.model)")
            }
            return ""
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cfg.whisper)
        p.arguments = ["-m", cfg.model, "-f", wav.path, "-l", lang,
                       "-nt", "-np", "--no-prints", "-t", "4"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            DispatchQueue.main.async {
                self.alert(T("whisper-cli not found"), uiLang() == "vi"
                    ? "Mong đợi tại \(self.cfg.whisper)\n\nCài bằng: brew install whisper-cpp"
                    : "Expected at \(self.cfg.whisper)\n\nInstall with: brew install whisper-cpp")
            }
            return ""
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return cleanTranscript(String(data: data, encoding: .utf8) ?? "")
    }
}

if CommandLine.arguments.contains("--selftest") { runSelfTest() }
if CommandLine.arguments.contains("--checkperms") { runPermCheck() }

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
