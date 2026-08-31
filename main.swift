import Cocoa
import AVFoundation

/// Serial: chunks must be typed in the order they were spoken.
let streamQueue = DispatchQueue(label: "voicekey.stream")


// ---------- recorder ----------

final class Recorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var isRecording = false

    private(set) var url = historyDir.appendingPathComponent("voicekey.wav")

    /// Set to stream: called off the main thread with each finished chunk while the
    /// key is still held. nil = one wav for the whole clip (the classic path).
    var onChunk: ((URL) -> Void)?
    private var outFormat: AVAudioFormat?
    private var chunkFrames: Int64 = 0
    private var silentFrames: Int64 = 0
    /// Cut only at a pause — mid-word cuts are what make chunked whisper sound drunk.
    private let minChunk: Int64 = 16000 * 3, silenceToCut: Int64 = 16000 / 2
    private let silenceRMS: Float = 0.012

    private func newFile() throws {
        url = historyDir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).wav")
        file = try AVAudioFile(forWriting: url, settings: outFormat!.settings,
                               commonFormat: .pcmFormatInt16, interleaved: true)
        chunkFrames = 0; silentFrames = 0
    }

    /// Closes the current chunk at a silence and hands it over, then opens the next.
    private func rotate() {
        guard let onChunk, chunkFrames >= minChunk, silentFrames >= silenceToCut else { return }
        let done = url
        file = nil
        guard (try? newFile()) != nil else { return }
        onChunk(done)
    }

    func start() throws {
        guard !isRecording else { return }
        try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        url = historyDir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).wav")
        let input = engine.inputNode
        // Must be set before the format is read — the node re-tags itself on device change.
        let micUID = Settings.shared.cfg.micUID
        if !micUID.isEmpty, let dev = Audio.device(uid: micUID), let unit = input.audioUnit {
            var id = dev
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw NSError(domain: "voicekey", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no audio input device"]) }

        // whisper wants 16 kHz mono
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                      channels: 1, interleaved: true)!
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        self.outFormat = outFormat
        file = try AVAudioFile(forWriting: url, settings: outFormat.settings,
                               commonFormat: .pcmFormatInt16, interleaved: true)
        chunkFrames = 0; silentFrames = 0

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

                if self.onChunk != nil {
                    let n = Int64(out.frameLength)
                    self.chunkFrames += n
                    self.silentFrames = rms < self.silenceRMS ? self.silentFrames + n : 0
                    self.rotate()
                }
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


// ---------- accessibility reads ----------

/// The focused text field of the frontmost app, via the same Accessibility
/// permission we already need to paste. Nothing here is stored or sent anywhere
/// except (for Deep Context) the local whisper process.
private func focusedElement() -> AXUIElement? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    var el: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                        kAXFocusedUIElementAttribute as CFString, &el) == .success
    else { return nil }
    return (el as! AXUIElement)
}

private func axString(_ el: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
          let s = v as? String, !s.isEmpty else { return nil }
    return s
}

/// Text the user has highlighted right now, if any.
func selectedText() -> String? {
    if let s = focusedElement().flatMap({ axString($0, kAXSelectedTextAttribute as String) })?
        .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty { return s }
    let copied = copiedSelection()
    log("selection: ax=nil clipboard=\(copied?.count.description ?? "nil")")
    return copied
}

/// Electron apps (VS Code, Slack, Discord) don't publish kAXSelectedTextAttribute,
/// so fall back to a synthetic \u{2318}C. The pasteboard is cleared first: copying with
/// nothing selected leaves changeCount untouched, which is how we tell an empty
/// selection from a stale clipboard.
private func copiedSelection() -> String? {
    let pb = NSPasteboard.general
    let saved = pb.string(forType: .string)
    let before = pb.clearContents()

    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)   // c
    let up = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
    // Explicit flags — the talk key is physically held down right now.
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)

    // The target app copies asynchronously; give it up to 300ms.
    var text: String?
    for _ in 0..<20 {
        usleep(15_000)
        if pb.changeCount != before { text = pb.string(forType: .string); break }
    }
    pb.clearContents()
    if let saved { pb.setString(saved, forType: .string) }
    return text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
}

/// A short sample of what's on screen around the cursor, used as whisper's initial
/// prompt so names and jargon already in the document get transcribed correctly.
/// whisper only keeps ~224 tokens of prompt, so send the tail, not the whole doc.
func screenContext() -> String? {
    guard let el = focusedElement() else { return nil }
    var parts: [String] = []
    if let app = NSWorkspace.shared.frontmostApplication?.localizedName { parts.append(app) }
    if let title = axString(el, kAXTitleAttribute as String) { parts.append(title) }
    if let value = axString(el, kAXValueAttribute as String) { parts.append(String(value.suffix(600))) }
    return parts.joined(separator: ". ").nilIfEmpty
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
    /// Key that double-tap latched recording on — the next tap of it stops the clip.
    var latchedCode: Int64?
    var pressedAt: Date?         // when the current press started, to tell tap from hold
    var lastTapAt: Date?         // when the previous short tap ended
    var lastTranscript = ""
    var targetApp: String?
    /// Text that was highlighted when the key went down — Select to Edit rewrites it.
    var editing: String?
    /// Deep Context sample of the focused field, fed to whisper as an initial prompt.
    var context: String?

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
        // Ignore the other key while one is already held or latched, so the language
        // can't switch mid-clip.
        guard heldCode == nil || heldCode == code else { return Unmanaged.passUnretained(event) }
        guard latchedCode == nil || latchedCode == code else { return Unmanaged.passUnretained(event) }

        if let flag = modifierFlags[code] {
            guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
            let pressed = event.flags.contains(flag)
            if pressed != (heldCode == code) {
                heldCode = pressed ? code : nil
                DispatchQueue.main.async {
                    pressed ? self.keyPressed(code, lang) : self.keyReleased(code, lang)
                }
            }
            return Unmanaged.passUnretained(event)   // don't break the modifier for other apps
        }

        // plain key: swallow it so holding it doesn't spam characters
        if type == .keyDown && heldCode == nil {
            heldCode = code
            DispatchQueue.main.async { self.keyPressed(code, lang) }
        } else if type == .keyUp {
            heldCode = nil
            DispatchQueue.main.async { self.keyReleased(code, lang) }
        }
        return nil
    }

    // MARK: press / release

    func keyPressed(_ code: Int64, _ lang: String) {
        guard latchedCode != code else { return }   // latched: the release is what stops it
        pressedAt = Date()
        beginTalk(lang)
    }

    func keyReleased(_ code: Int64, _ lang: String) {
        let held = pressedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let gap = lastTapAt.map { Date().timeIntervalSince($0) }
        pressedAt = nil

        switch tapAction(latched: latchedCode == code, enabled: cfg.doubleTapLatch,
                         held: held, sinceLastTap: gap) {
        case .transcribe:              // a real hold, or the tap that ends a latch
            latchedCode = nil
            lastTapAt = nil
            endTalk(lang)
        case .latch:                   // second tap: the clip this press started keeps running
            lastTapAt = nil
            latchedCode = code
        case .discard:                 // first tap — too short to hold speech; wait for a second
            lastTapAt = Date()
            cancelTalk(silent: true)
        }
    }

    // MARK: talk

    var isTalking: Bool { rec.isRecording }

    func cancelTalk(silent: Bool = false) {
        handsFreeLang = nil
        heldCode = nil
        latchedCode = nil
        pressedAt = nil
        if let wav = rec.stop() { try? FileManager.default.removeItem(at: wav) }
        setIcon("mic")
        HUD.shared.hide()
        if cfg.playSounds && !silent { NSSound(named: "Funk")?.play() }
    }

    func beginTalk(_ lang: String) {
        // Grab it now — after we paste, the frontmost app may have changed.
        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
        // Same reason: the selection and the field contents must be read before we type.
        editing = cfg.selectToEdit ? selectedText() : nil
        log("begin lang=\(lang) app=\(targetApp ?? "?") "
            + "selectToEdit=\(cfg.selectToEdit) selection=\(editing?.count.description ?? "nil") "
            + "streaming=\(cfg.streaming) ai=\(cfg.aiEnabled)")
        context = cfg.deepContext ? screenContext() : nil
        // Streaming needs one fixed language; with auto-detect whisper can flip
        // language between chunks, and editing needs the whole instruction at once.
        // onChunk fires on the audio render thread; whisper takes seconds, and blocking
        // there stalls recording and drops the rest of the clip. Hop off it first.
        rec.onChunk = (cfg.streaming == "auto" && lang != "auto" && editing == nil)
            ? { [weak self] wav in
                  streamQueue.async { self?.streamChunk(wav, lang) }
              } : nil
        do {
            try rec.start()
            setIcon("waveform")
            if cfg.playSounds { NSSound(named: "Tink")?.play() }
            Meter.shared.reset()
            HUD.shared.show(.listening, lang: lang)
        } catch {
            setIcon("exclamationmark.triangle")
            HUD.shared.hide()
            log("record failed: \(error.localizedDescription)")
        }
    }

    /// A mid-clip chunk: transcribe and type it right away, so long dictations land
    /// sentence by sentence instead of all at the end. Runs off the main thread.
    func streamChunk(_ wav: URL, _ lang: String) {
        DispatchQueue.main.async {
            Stream.shared.busy = true
            HUD.shared.show(.streaming, lang: lang)
        }
        let text = transcribe(wav, lang)
        log("stream chunk → \(text.isEmpty ? "<empty>" : text)")
        DispatchQueue.main.async {
            Stream.shared.busy = false
            if self.cfg.privacyMode { try? FileManager.default.removeItem(at: wav) }
            else { History.shared.add(audio: wav, text: text) }
            guard !text.isEmpty else { return }
            let out = self.casual(text) + " "
            StatStore.shared.record(words: text.split(separator: " ").count,
                                    seconds: 0, app: self.targetApp)
            self.lastTranscript = out
            typeText(out, conceal: self.cfg.avoidClipboardHistory)
            Stream.shared.push(out.trimmingCharacters(in: .whitespaces))
            HUD.shared.show(.streaming, lang: lang)
        }
    }

    /// The cleanup prompt for whatever app we're dictating into.
    func promptForApp() -> String {
        guard cfg.appModesEnabled, let m = appMode(targetApp) else { return cfg.aiPrompt }
        return cfg.aiPrompt + "\n\n" + m.hint
    }

    func casual(_ t: String) -> String {
        cfg.casualMessaging && isCasualApp(targetApp) ? t.lowercased() : t
    }

    func endTalk(_ lang: String) {
        rec.onChunk = nil
        guard let wav = rec.stop() else {
            setIcon("mic"); Stream.shared.clear(); HUD.shared.hide(); return
        }
        setIcon("hourglass")
        // Mid-stream the card is already up; swapping it for the capsule just flickers.
        if Stream.shared.lines.isEmpty {
            HUD.shared.show(.transcribing, lang: lang)
        } else {
            Stream.shared.busy = true
            HUD.shared.show(.streaming, lang: lang)
        }
        // Measure before Privacy Mode deletes the file out from under us.
        let secs = (try? AVAudioFile(forReading: wav)).map {
            Double($0.length) / $0.fileFormat.sampleRate } ?? 0
        DispatchQueue.global(qos: .userInitiated).async {
            var text = self.transcribe(wav, lang)
            // Select to Edit: the words were an instruction, not the text to insert.
            // Privacy Mode keeps the selection on the Mac, so it falls back to a paste.
            if let sel = self.editing, !text.isEmpty, !self.cfg.privacyMode {
                do { text = try aiEdit(selection: sel, instruction: text, model: self.cfg.aiModel) }
                catch {
                    // Pasting the raw instruction would eat the selection — do nothing instead.
                    log("select-to-edit FAILED: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.setIcon("mic"); HUD.shared.hide()
                        self.alert(T("Edit failed"), error.localizedDescription)
                        try? FileManager.default.removeItem(at: wav)
                    }
                    return
                }
            } else if self.cfg.aiEnabled && !self.cfg.privacyMode && !text.isEmpty {
                // Privacy Mode means nothing leaves the Mac, so it wins over AI cleanup.
                do { text = try aiClean(text, model: self.cfg.aiModel, prompt: self.promptForApp()) }
                catch { log("ai cleanup skipped: \(error.localizedDescription)") }
            }
            let final = self.editing == nil ? self.casual(text) : text
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
        log("transcribe \(wav.lastPathComponent) lang=\(lang) context=\(self.context?.count ?? 0)")
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
        if let context { p.arguments! += ["--prompt", context] }
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
        let text = cleanTranscript(String(data: data, encoding: .utf8) ?? "")
        log("whisper lang=\(lang) exit=\(p.terminationStatus) → \(text.isEmpty ? "<empty>" : text)")
        return text
    }
}

if CommandLine.arguments.contains("--selftest") { runSelfTest() }
if CommandLine.arguments.contains("--checkperms") { runPermCheck() }

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
