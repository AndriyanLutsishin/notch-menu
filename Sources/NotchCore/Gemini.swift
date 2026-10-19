import Foundation

/// Gemini від Google: безкоштовно через Gemini CLI (вхід Google-акаунтом) або безкоштовний ключ з AI Studio.
public enum GeminiAPI {
    public static let base = "https://generativelanguage.googleapis.com/v1beta"
    /// Запасна модель, якщо список моделей не отримали.
    public static let fallbackModel = "gemini-3.5-flash"

    public static func modelsRequest(apiKey: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "\(base)/models?pageSize=200")!)
        r.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        r.timeoutInterval = 20
        return r
    }

    /// Найновіші моделі «Flash» (без lite/preview/image/tts), від нової до старої.
    public static func pickModels(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        var found: [(version: [Int], name: String)] = []
        for m in models {
            guard let full = m["name"] as? String,
                  (m["supportedGenerationMethods"] as? [String])?.contains("generateContent") ?? true else { continue }
            let name = full.hasPrefix("models/") ? String(full.dropFirst(7)) : full
            guard let r = name.range(of: #"^gemini-(\d+(\.\d+)?)-flash$"#, options: .regularExpression), r == name.startIndex..<name.endIndex else { continue }
            let ver = name.dropFirst("gemini-".count).prefix { $0 != "-" }.split(separator: ".").compactMap { Int($0) }
            found.append((ver, name))
        }
        return found.sorted { $0.version.lexicographicallyPrecedes($1.version) }.reversed().map(\.name)
    }

    public static func makeRequest(prompt: String, model: String, apiKey: String) throws -> URLRequest {
        var r = URLRequest(url: URL(string: "\(base)/models/\(model):streamGenerateContent?alt=sse")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 300
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": ClaudeAPI.systemPrompt]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
        ]
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    /// Рядок потоку `data: {...}` → шматок тексту.
    public static func parseStreamLine(_ line: String) -> ClaudeAPI.StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = json["error"] as? [String: Any] {
            return .error(friendlyError(status: err["code"] as? Int, message: err["message"] as? String))
        }
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { return nil }
        let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        // «Думки» моделі (thought: true) не показуємо — лише відповідь.
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        if !text.isEmpty { return .text(text) }
        if let reason = candidate["finishReason"] as? String, reason != "STOP" { return .stop(reason: reason == "MAX_TOKENS" ? "max_tokens" : reason) }
        return nil
    }

    public static func friendlyError(status: Int?, message: String?) -> String {
        let msg = message ?? ""
        switch status {
        case 400 where msg.localizedCaseInsensitiveContains("API key"), 401, 403:
            return "Ключ Gemini не підходить. Створи новий на aistudio.google.com/apikey."
        case 429:
            return "Вичерпано безкоштовний ліміт Gemini. Спробуй за хвилину (або завтра, якщо денний ліміт)."
        case let s? where s >= 500:
            return "Сервер Gemini не відповідає (\(s)). Спробуй трохи згодом."
        default:
            return msg.isEmpty ? "Gemini не відповів." : "Помилка Gemini: \(msg)"
        }
    }
}
