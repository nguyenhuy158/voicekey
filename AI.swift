import Foundation

// ---------- API key ----------

/// The key is a credential, so it lives in the Keychain, not in world-readable config.json.
enum Keychain {
    static let account = "openrouter"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.voicekey",
         kSecAttrAccount as String: account]
    }

    static func get() -> String {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func set(_ value: String) {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

// ---------- cleanup ----------

/// Fallback only — OpenRouter retires free slugs without notice, so the real list
/// is fetched from the API at runtime (see fetchFreeModels).
let freeModels = [
    "z-ai/glm-5.2:free",
    "google/gemma-4-31b-it:free",
    "google/gemma-4-26b-a4b-it:free",
    "minimax/minimax-m2.7:free",
    "nvidia/nemotron-3.5-lightning:free",
]

/// The live list of :free models. No API key needed. Silent on failure — the
/// hardcoded list above keeps working.
func fetchFreeModels(_ done: @escaping ([String]) -> Void) {
    var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
    req.timeoutInterval = 10
    URLSession.shared.dataTask(with: req) { data, _, _ in
        guard let d = data,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let models = j["data"] as? [[String: Any]] else { return }
        let ids = models.compactMap { $0["id"] as? String }.filter { $0.hasSuffix(":free") }.sorted()
        guard !ids.isEmpty else { return }
        DispatchQueue.main.async { done(ids) }
    }.resume()
}

let defaultAIPrompt = """
You clean up speech-to-text output. Fix punctuation, capitalisation and obvious \
mis-transcriptions. Keep the speaker's exact wording, language and meaning — do not \
translate, summarise, answer, or add anything. Technical terms and product names \
spoken in English inside another language stay in English. Reply with the corrected \
text only, nothing else.
"""

let editPrompt = """
You edit text in place. The user gives you SELECTION (the text they highlighted) and \
INSTRUCTION (what they said out loud). Apply the instruction to the selection and reply \
with the edited text only — no quotes, no explanation, no preamble. Keep the original \
language unless the instruction asks otherwise. If the instruction is not an edit \
request, treat it as replacement text.
"""

/// Rewrites `selection` according to a spoken `instruction`. Same transport as
/// aiClean, different contract — here the reply legitimately differs a lot from
/// the input, so aiClean's length guard would be wrong.
func aiEdit(selection: String, instruction: String, model: String,
            timeout: TimeInterval = 20) throws -> String {
    log("aiEdit model=\(model)")
    let body = "SELECTION:\n\(selection)\n\nINSTRUCTION:\n\(instruction)"
    let out = try aiRequest(system: editPrompt, user: body, model: model, timeout: timeout)
    guard !out.isEmpty else { throw AIError.badResponse }
    return out
}

enum AIError: LocalizedError {
    case noKey, http(Int, String), badResponse
    var errorDescription: String? {
        switch self {
        case .noKey: return "No OpenRouter API key set."
        case .http(let c, let body): return "OpenRouter returned \(c): \(body.prefix(200))"
        case .badResponse: return "Unexpected response from OpenRouter."
        }
    }
}

/// Blocking — call it off the main thread. Throws so the caller can decide;
/// dictation itself always falls back to the raw transcript.
func aiClean(_ text: String, model: String, prompt: String, timeout: TimeInterval = 12) throws -> String {
    log("aiClean model=\(model)")
    let cleaned = try aiRequest(system: prompt, user: text, model: model, timeout: timeout)
    // A model that rambles or returns nothing is worse than the raw transcript.
    guard !cleaned.isEmpty, cleaned.count < text.count * 3 + 200 else { return text }
    return cleaned
}

/// One blocking chat completion. Call it off the main thread.
private func aiRequest(system: String, user: String, model: String,
                       timeout: TimeInterval) throws -> String {
    let key = Keychain.get()
    guard !key.isEmpty else { throw AIError.noKey }

    var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
    req.httpMethod = "POST"
    req.timeoutInterval = timeout
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("VoiceKey", forHTTPHeaderField: "X-Title")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": model,
        "temperature": 0,
        "messages": [["role": "system", "content": system],
                     ["role": "user", "content": user]],
    ])

    var out: Result<String, Error>!
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, err in
        defer { done.signal() }
        if let err { out = .failure(err); return }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard code == 200 else { out = .failure(AIError.http(code, body)); return }
        guard let d = data,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let choices = j["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            out = .failure(AIError.badResponse); return
        }
        out = .success(content.trimmingCharacters(in: .whitespacesAndNewlines))
    }.resume()
    done.wait()
    return try out.get()
}
