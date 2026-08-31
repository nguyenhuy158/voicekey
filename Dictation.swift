import Foundation

/// Serial: chunks must be typed in the order they were spoken.
let streamQueue = DispatchQueue(label: "voicekey.stream")

/// The application core. Owns one dictation gesture from key-down to pasted
/// text: latching, streaming chunks, AI cleanup, history and stats. It reaches
/// the outside world only through the ports, so the whole state machine runs
/// headless in the selftest.
final class Dictation {
    private let audio: AudioPort
    private let stt: TranscribePort
    let text: TextPort
    private let ai: AIPort
    private let ui: FeedbackPort
    private let store: StorePort

    var cfg: Config { Settings.shared.cfg }

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
    /// Bumped every time a clip starts or is thrown away. A streaming chunk that
    /// finishes after its clip is gone must not paste — that's how one gesture ended
    /// up typing twice.
    var clipID = 0

    init(audio: AudioPort, stt: TranscribePort, text: TextPort,
         ai: AIPort, ui: FeedbackPort, store: StorePort) {
        self.audio = audio; self.stt = stt; self.text = text
        self.ai = ai; self.ui = ui; self.store = store
    }

    var isTalking: Bool { audio.isRecording }

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

    /// Hands free: one tap starts, the next stops.
    func toggleHandsFree() {
        if let lang = handsFreeLang { handsFreeLang = nil; endTalk(lang) }
        else { handsFreeLang = cfg.language; beginTalk(cfg.language) }
    }

    func pasteLast() {
        guard !lastTranscript.isEmpty else { return }
        text.type(lastTranscript, conceal: cfg.avoidClipboardHistory)
    }

    // MARK: talk

    func cancelTalk(silent: Bool = false) {
        clipID += 1                 // anything still transcribing belongs to a dead clip
        audio.onChunk = nil
        handsFreeLang = nil
        heldCode = nil
        latchedCode = nil
        pressedAt = nil
        if let wav = audio.stop() { try? FileManager.default.removeItem(at: wav) }
        ui.icon("mic")
        ui.hideHUD()
        if cfg.playSounds && !silent { ui.sound("Funk") }
    }

    func beginTalk(_ lang: String) {
        // Grab it now — after we paste, the frontmost app may have changed.
        targetApp = text.frontApp()
        // Same reason: the selection and the field contents must be read before we type.
        editing = cfg.selectToEdit ? text.selection() : nil
        log("begin lang=\(lang) app=\(targetApp ?? "?") "
            + "selectToEdit=\(cfg.selectToEdit) selection=\(editing?.count.description ?? "nil") "
            + "streaming=\(cfg.streaming) ai=\(cfg.aiEnabled)")
        context = cfg.deepContext ? text.context() : nil
        // Streaming needs one fixed language; with auto-detect whisper can flip
        // language between chunks, and editing needs the whole instruction at once.
        // onChunk fires on the audio render thread; whisper takes seconds, and blocking
        // there stalls recording and drops the rest of the clip. Hop off it first.
        clipID += 1
        let clip = clipID
        audio.onChunk = (cfg.streaming == "auto" && lang != "auto" && editing == nil)
            ? { [weak self] wav in
                  streamQueue.async { self?.streamChunk(wav, lang, clip) }
              } : nil
        do {
            try audio.start()
            ui.icon("waveform")
            if cfg.playSounds { ui.sound("Tink") }
            Meter.shared.reset()
            ui.hud(.listening, lang: lang)
        } catch {
            ui.icon("exclamationmark.triangle")
            ui.hideHUD()
            log("record failed: \(error.localizedDescription)")
        }
    }

    /// A mid-clip chunk: transcribe and type it right away, so long dictations land
    /// sentence by sentence instead of all at the end. Runs off the main thread.
    func streamChunk(_ wav: URL, _ lang: String, _ clip: Int) {
        DispatchQueue.main.async {
            Stream.shared.busy = true
            self.ui.hud(.streaming, lang: lang)
        }
        let out = transcribe(wav, lang)
        log("stream chunk (clip \(clip)) → \(out.isEmpty ? "<empty>" : out)")
        DispatchQueue.main.async {
            Stream.shared.busy = false
            guard clip == self.clipID else {
                log("stream chunk dropped: clip \(clip) is over")
                try? FileManager.default.removeItem(at: wav)
                return
            }
            if self.cfg.privacyMode { try? FileManager.default.removeItem(at: wav) }
            else { self.store.keep(audio: wav, text: out) }
            guard !out.isEmpty else { return }
            let typed = self.casual(out) + " "
            self.store.record(words: out.split(separator: " ").count,
                              seconds: 0, app: self.targetApp)
            self.lastTranscript = typed
            self.text.type(typed, conceal: self.cfg.avoidClipboardHistory)
            Stream.shared.push(typed.trimmingCharacters(in: .whitespaces))
            self.ui.hud(.streaming, lang: lang)
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
        audio.onChunk = nil
        guard let wav = audio.stop() else {
            ui.icon("mic"); Stream.shared.clear(); ui.hideHUD(); return
        }
        ui.icon("hourglass")
        // Mid-stream the card is already up; swapping it for the capsule just flickers.
        if Stream.shared.lines.isEmpty {
            ui.hud(.transcribing, lang: lang)
        } else {
            Stream.shared.busy = true
            ui.hud(.streaming, lang: lang)
        }
        let secs = duration(wav)
        // Same queue as the streaming chunks: the tail must be typed after any chunk
        // still in flight, not race ahead of it.
        streamQueue.async { self.finish(wav, lang, secs) }
    }

    /// Transcribe → AI → paste. Off the main thread; only the last hop hops back.
    private func finish(_ wav: URL, _ lang: String, _ secs: Double) {
        var out = transcribe(wav, lang)
        // Select to Edit: the words were an instruction, not the text to insert.
        // Privacy Mode keeps the selection on the Mac, so it falls back to a paste.
        if let sel = editing, !out.isEmpty, !cfg.privacyMode {
            do { out = try ai.edit(selection: sel, instruction: out, model: cfg.aiModel) }
            catch {
                // Pasting the raw instruction would eat the selection — do nothing instead.
                log("select-to-edit FAILED: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.ui.icon("mic"); self.ui.hideHUD()
                    self.ui.alert(T("Edit failed"), error.localizedDescription)
                    try? FileManager.default.removeItem(at: wav)
                }
                return
            }
        } else if cfg.aiEnabled && !cfg.privacyMode && !out.isEmpty {
            // Privacy Mode means nothing leaves the Mac, so it wins over AI cleanup.
            do { out = try ai.clean(out, model: cfg.aiModel, prompt: promptForApp()) }
            catch { log("ai cleanup skipped: \(error.localizedDescription)") }
        }
        let final = editing == nil ? casual(out) : out
        DispatchQueue.main.async { self.land(final, wav, secs) }
    }

    /// The main-thread tail of a finished clip: icon, history, stats, paste.
    private func land(_ final: String, _ wav: URL, _ secs: Double) {
        ui.icon("mic")
        ui.hideHUD()
        if cfg.playSounds { ui.sound("Pop") }
        if cfg.privacyMode { try? FileManager.default.removeItem(at: wav) }
        else { store.keep(audio: wav, text: final) }
        guard !final.isEmpty else { return }
        store.record(words: final.split(separator: " ").count, seconds: secs, app: targetApp)
        lastTranscript = final
        text.type(final, conceal: cfg.avoidClipboardHistory)
    }

    func transcribe(_ wav: URL, _ lang: String) -> String {
        log("transcribe \(wav.lastPathComponent) lang=\(lang) context=\(context?.count ?? 0)")
        do { return try stt.transcribe(wav, lang: lang, context: context) }
        catch {
            let (title, msg) = explain(error)
            DispatchQueue.main.async { self.ui.alert(title, msg) }
            return ""
        }
    }

    /// Why transcription failed, in the user's language and with the fix.
    func explain(_ error: Error) -> (String, String) {
        let vi = uiLang() == "vi"
        switch error {
        case TranscribeError.modelMissing(let path):
            return (T("Model missing"), vi
                ? "Chạy ./setup.sh để tải mô hình whisper.\n\nĐường dẫn mong đợi:\n\(path)"
                : "Run ./setup.sh to download the whisper model.\n\nExpected at:\n\(path)")
        case TranscribeError.toolMissing(let path):
            return (T("whisper-cli not found"), vi
                ? "Mong đợi tại \(path)\n\nCài bằng: brew install whisper-cpp"
                : "Expected at \(path)\n\nInstall with: brew install whisper-cpp")
        default:
            return (T("Transcription failed"), error.localizedDescription)
        }
    }
}
