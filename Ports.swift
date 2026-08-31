import Foundation

// Ports. Everything the dictation core needs from the outside world lives behind
// one of these; Dictation.swift talks to nothing else. Adapters.swift holds the
// real macOS implementations, SelfTest.swift holds fakes — which is the whole
// point: the clip state machine can be driven in CI with no mic, no whisper,
// no network and no Accessibility grant.

protocol AudioPort: AnyObject {
    var isRecording: Bool { get }
    /// Set to stream: called off the main thread with each finished chunk while
    /// the key is still held. nil = one wav for the whole clip.
    var onChunk: ((URL) -> Void)? { get set }
    func start() throws
    /// nil = the clip was too short to bother with.
    func stop() -> URL?
}

enum TranscribeError: Error {
    case modelMissing(String)   // path to the model we expected
    case toolMissing(String)    // path to whisper-cli
}

protocol TranscribePort {
    func transcribe(_ wav: URL, lang: String, context: String?) throws -> String
}

protocol TextPort {
    func type(_ text: String, conceal: Bool)
    /// What the user has highlighted right now, if anything.
    func selection() -> String?
    /// A sample of the focused field, used as whisper's initial prompt.
    func context() -> String?
    func frontApp() -> String?
}

protocol AIPort {
    func clean(_ text: String, model: String, prompt: String) throws -> String
    func edit(selection: String, instruction: String, model: String) throws -> String
}

protocol FeedbackPort {
    func icon(_ symbol: String)
    func hud(_ state: HUDState, lang: String)
    func hideHUD()
    func sound(_ name: String)
    func alert(_ title: String, _ message: String)
}

protocol StorePort {
    func keep(audio: URL, text: String)
    func record(words: Int, seconds: Double, app: String?)
}
