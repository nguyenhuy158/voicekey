import Cocoa
import AVFoundation
import CoreAudio

// Pure logic, no AppKit event loop: config, key names, tap-vs-hold,
// app modes, audio devices and transcript cleanup. Split out of main.swift
// so ./cov.sh can hold it to a real coverage bar.

// ---------- config ----------

let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/voicekey")
/// Via historyRoot so the selftest writes to a scratch dir, not your real config.
let configURL = historyRoot.appendingPathComponent("config.json")

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

    /// CoreAudio device UID; empty = whatever macOS calls the default input.
    var micUID = ""
    /// Lowercase the transcript when dictating into a chat app.
    var casualMessaging = false
    /// Adapt AI cleanup to the app being dictated into (terminal, editor, chat, …).
    var appModesEnabled = false
    /// Feed the focused field's text to whisper as an initial prompt.
    var deepContext = false
    /// Dictate over a selection to rewrite it instead of replacing it verbatim.
    var selectToEdit = false
    /// "never" or "auto" — auto types each sentence as you pause, mid-clip.
    var streaming = "never"

    var floatingBar = false
    var playSounds = true
    var avoidClipboardHistory = true
    var privacyMode = false
    /// Double-tap a talk key to latch recording on; tap again to stop.
    var doubleTapLatch = true
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
        micUID = f(.micUID, d.micUID)
        casualMessaging = f(.casualMessaging, d.casualMessaging)
        appModesEnabled = f(.appModesEnabled, d.appModesEnabled)
        deepContext = f(.deepContext, d.deepContext)
        selectToEdit = f(.selectToEdit, d.selectToEdit)
        streaming = f(.streaming, d.streaming)
        floatingBar = f(.floatingBar, d.floatingBar)
        playSounds = f(.playSounds, d.playSounds)
        avoidClipboardHistory = f(.avoidClipboardHistory, d.avoidClipboardHistory)
        privacyMode = f(.privacyMode, d.privacyMode)
        doubleTapLatch = f(.doubleTapLatch, d.doubleTapLatch)
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

// ---------- tap vs hold ----------

/// A press shorter than this is a tap, not a hold.
let tapMax = 0.35
/// Two taps closer together than this latch recording on.
let doubleTapGap = 0.45

enum TapAction { case transcribe, latch, discard }

/// What releasing a talk key should do. `held` is how long it was down, `sinceLastTap`
/// how long ago the previous short tap ended (nil = there wasn't one).
func tapAction(latched: Bool, enabled: Bool, held: Double, sinceLastTap: Double?) -> TapAction {
    if latched { return .transcribe }            // the tap that ends a latched clip
    if !enabled || held >= tapMax { return .transcribe }
    if let gap = sinceLastTap, gap < doubleTapGap { return .latch }
    return .discard
}

/// Apps where sentence case reads as shouting. Matched loosely on the app name.
let casualApps = ["slack", "messages", "imessage", "discord", "telegram", "whatsapp",
                  "messenger", "zalo", "signal", "teams"]

func isCasualApp(_ name: String?) -> Bool {
    guard let n = name?.lowercased() else { return false }
    return casualApps.contains { n.contains($0) }
}

// ---------- app-specific modes ----------

/// Dictating into a terminal, an editor and a Slack thread want different text.
/// The mode is a line appended to the AI cleanup prompt — no separate transport,
/// no per-app engine. Matched loosely on the frontmost app's name, first hit wins.
let appModes: [(name: String, apps: [String], hint: String)] = [
    ("Terminal", ["terminal", "iterm", "warp", "ghostty", "alacritty", "kitty", "wezterm"],
     "The text is a shell command. Output it as a single command line: no sentence capitalisation, no trailing full stop, flags keep their dashes, paths and file names stay verbatim."),
    ("Editor", ["cursor", "code", "xcode", "zed", "sublime", "jetbrains", "intellij",
                "pycharm", "webstorm", "goland", "android studio", "neovim", "nvim"],
     "The text is written to a code editor. Keep identifiers, file names, APIs and symbols exactly as spoken, in English; do not capitalise them as prose."),
    ("Chat", casualApps,
     "The text is a chat message. Keep it short and informal, no sentence-final full stop, no formal rewording."),
    ("Prompt", ["chatgpt", "claude", "gemini", "perplexity", "copilot", "grok"],
     "The text is a prompt to an AI assistant. Keep the instruction intact and imperative; do not answer it, soften it, or add pleasantries."),
    ("Browser", ["safari", "chrome", "firefox", "arc", "edge", "brave", "orion", "vivaldi"],
     "The text is typed into a web page. Plain prose, standard punctuation, no markdown."),
]

/// Which mode an app name falls into, if any. Editor before Browser matters:
/// "Visual Studio Code" contains "code", and Chrome-based editors exist.
func appMode(_ name: String?) -> (name: String, apps: [String], hint: String)? {
    guard let n = name?.lowercased() else { return nil }
    return appModes.first { $0.apps.contains { n.contains($0) } }
}

// ---------- audio devices ----------

/// CoreAudio input devices. UID is stable across reboots and unplugs; the numeric
/// AudioDeviceID is not, so config stores the UID.
struct Mic: Identifiable, Hashable {
    let id: AudioDeviceID, uid: String, name: String
}

enum Audio {
    static func inputs() -> [Mic] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).map { Mic(id: $0, uid: string($0, kAudioDevicePropertyDeviceUID) ?? "",
                                              name: string($0, kAudioObjectPropertyName) ?? "?") }
    }

    /// A device with no input streams is a speaker, not a mic.
    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return false }
        let list = buf.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString>.size)
        var out = "" as CFString
        let ok = withUnsafeMutablePointer(to: &out) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) == noErr
        }
        return ok ? out as String : nil
    }

    static func device(uid: String) -> AudioDeviceID? {
        inputs().first { $0.uid == uid }?.id
    }
}


// ---------- transcript cleanup ----------

/// whisper emits marker-only lines like "[BLANK_AUDIO]" or "(silence)" for empty clips.
/// Drops those whole-line markers and joins the rest — a spoken "(like this)" must survive.
/// Whisper was trained on YouTube subtitles, so near-silent audio makes it emit
/// the outro its training data ends with. Nobody dictates these, so drop the line.
let hallucinations = [
    "subscribe", "đăng ký kênh", "ghiền mì gõ", "lala school",
    "hẹn gặp lại các bạn", "cảm ơn các bạn đã theo dõi",
    "thanks for watching", "thank you for watching",
]

private func isHallucination(_ line: String) -> Bool {
    let l = line.lowercased()
    return hallucinations.contains { l.contains($0) }
}

func cleanTranscript(_ raw: String) -> String {
    raw.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && $0.range(of: "^(\\[.*\\]|\\(.*\\))$",
                                          options: .regularExpression) == nil }
        .filter { !isHallucination(String($0)) }
        .joined(separator: " ")
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Length of a wav in seconds, or 0 if it can't be read — measured before
/// Privacy Mode deletes the file out from under us.
func duration(_ wav: URL) -> Double {
    (try? AVAudioFile(forReading: wav)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
}
