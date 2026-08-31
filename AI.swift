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

let freeModels = [
    "deepseek/deepseek-chat-v3-0324:free",
    "meta-llama/llama-3.3-70b-instruct:free",
    "qwen/qwen-2.5-72b-instruct:free",
    "google/gemma-3-27b-it:free",
]

let defaultAIPrompt = """
You clean up speech-to-text output. Fix punctuation, capitalisation and obvious \
mis-transcriptions. Keep the speaker's exact wording, language and meaning — do not \
translate, summarise, answer, or add anything. Technical terms and product names \
spoken in English inside another language stay in English. Reply with the corrected \
text only, nothing else.
"""

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
        "messages": [["role": "system", "content": prompt],
                     ["role": "user", "content": text]],
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

    let cleaned = try out.get()
    // A model that rambles or returns nothing is worse than the raw transcript.
    guard !cleaned.isEmpty, cleaned.count < text.count * 3 + 200 else { return text }
    return cleaned
}
