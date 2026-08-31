import Cocoa
import AVFoundation

// Driven adapters: the real macOS side of every port. Nothing in here is
// reachable from CI — a mic, whisper-cli, the Accessibility grant and the
// network all live behind this file, and that is deliberate.

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

/// Length of the current selection, or 0. Chrome and other web views happily
/// report kAXSelectedText for an unselected field, so the *range* is what decides
/// whether anything is really highlighted.
private func selectionLength(_ el: AXUIElement) -> Int? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString,
                                        &v) == .success else { return nil }
    var range = CFRange()
    guard AXValueGetValue(v as! AXValue, .cfRange, &range) else { return nil }
    return range.length
}

/// Text the user has highlighted right now, if any.
func selectedText() -> String? {
    if let el = focusedElement(), let n = selectionLength(el) {
        // The range is authoritative: 0 means nothing is highlighted, whatever
        // kAXSelectedText claims. No point asking the clipboard either.
        guard n > 0 else { log("selection: ax range=0, nothing highlighted"); return nil }
        if let s = axString(el, kAXSelectedTextAttribute as String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty { return s }
    }
    // No range attribute at all (Electron) — the clipboard round-trip is the only
    // way left, and it self-reports emptiness via changeCount.
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
    // whisper's --prompt is a vocabulary hint, not a document. Feeding it a long
    // dump (a terminal scrollback, say) makes it echo that text back and stutter,
    // so keep only the words nearest the cursor.
    if let value = axString(el, kAXValueAttribute as String) {
        parts.append(value.split(separator: " ").suffix(30).joined(separator: " "))
    }
    return parts.joined(separator: ". ").prefix(220).trimmingCharacters(in: .whitespaces).nilIfEmpty
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

// ---------- ports ----------

extension Recorder: AudioPort {}

/// whisper-cli in a subprocess. Missing model / missing binary come back as
/// errors so the core decides what the user is told, in their language.
struct Whisper: TranscribePort {
    func transcribe(_ wav: URL, lang: String, context: String?) throws -> String {
        let cfg = Settings.shared.cfg
        guard FileManager.default.fileExists(atPath: cfg.model) else {
            throw TranscribeError.modelMissing(cfg.model)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cfg.whisper)
        p.arguments = ["-m", cfg.model, "-f", wav.path, "-l", lang,
                       "-nt", "-np", "--no-prints", "-t", "4"]
        if let context { p.arguments! += ["--prompt", context] }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw TranscribeError.toolMissing(cfg.whisper) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = cleanTranscript(String(data: data, encoding: .utf8) ?? "")
        log("whisper lang=\(lang) exit=\(p.terminationStatus) → \(text.isEmpty ? "<empty>" : text)")
        return text
    }
}

struct SystemText: TextPort {
    func type(_ text: String, conceal: Bool) { typeText(text, conceal: conceal) }
    func selection() -> String? { selectedText() }
    func context() -> String? { screenContext() }
    func frontApp() -> String? { NSWorkspace.shared.frontmostApplication?.localizedName }
}

struct OpenRouter: AIPort {
    func clean(_ text: String, model: String, prompt: String) throws -> String {
        try aiClean(text, model: model, prompt: prompt)
    }
    func edit(selection: String, instruction: String, model: String) throws -> String {
        try aiEdit(selection: selection, instruction: instruction, model: model)
    }
}

/// Status icon, floating HUD, sounds and modal alerts. `setIcon` is injected
/// because the status item doesn't exist until the app finishes launching.
struct AppKitFeedback: FeedbackPort {
    var setIcon: (String) -> Void
    func icon(_ symbol: String) { setIcon(symbol) }
    func hud(_ state: HUDState, lang: String) { HUD.shared.show(state, lang: lang) }
    func hideHUD() { HUD.shared.hide() }
    func sound(_ name: String) { NSSound(named: name)?.play() }
    func alert(_ title: String, _ message: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

struct DiskStore: StorePort {
    func keep(audio: URL, text: String) { History.shared.add(audio: audio, text: text) }
    func record(words: Int, seconds: Double, app: String?) {
        StatStore.shared.record(words: words, seconds: seconds, app: app)
    }
}
