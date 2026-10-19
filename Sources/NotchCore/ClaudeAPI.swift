import Foundation

/// Хто відповідає на питання в панелі.
public enum AskProvider: String, CaseIterable, Identifiable, Sendable {
    case opus = "claude-opus-5-5"
    case fable = "claude-fable-5-1"
    case codex = "codex"
    case gemini = "gemini"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .opus: return "Opus 5.5"
        case .fable: return "Fable 5.1"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }

    /// Коротка назва для кнопки-перемикача.
    public var shortTitle: String {
        switch self {
        case .opus: return "Opus"
        case .fable: return "Fable"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }

    public var usesClaudeAPI: Bool { self == .opus || self == .fable }
}

/// Запит до Claude API напряму (без сторонніх бібліотек: у Swift немає офіційного SDK).
public enum ClaudeAPI {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let systemPrompt = """
        Ти — швидкий помічник у маленькій панелі на macOS. Відповідай стисло й по суті, \
        мовою запитання. Якщо просять переписати чи перекласти текст — дай лише результат.
        """

    /// Будує потоковий (streaming) запит: відповідь приходить шматочками й одразу видна.
    public static func makeRequest(prompt: String, model: AskProvider, apiKey: String) throws -> URLRequest {
        precondition(model.usesClaudeAPI)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Якщо модель відмовиться відповідати, сервер сам спробує запасну модель.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 64000,
            "stream": true,
            "system": systemPrompt,
            // Короткі питання — швидкий режим міркувань.
            "output_config": ["effort": "low"],
            "fallbacks": "default",
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Подія з потоку відповіді.
    public enum StreamEvent: Equatable, Sendable {
        case text(String)
        case stop(reason: String)
        case error(String)
    }

    /// Розбирає один рядок потоку (Server-Sent Events). Цікавлять лише рядки `data:`.
    public static func parseStreamLine(_ line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }

        switch type {
        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                return .text(text)
            }
        case "message_delta":
            if let delta = json["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String {
                return .stop(reason: reason)
            }
        case "error":
            let err = json["error"] as? [String: Any]
            return .error(friendlyError(type: err?["type"] as? String, message: err?["message"] as? String, status: nil))
        default:
            break
        }
        return nil
    }

    /// Зрозуміле пояснення помилки простою мовою.
    public static func friendlyError(type: String?, message: String?, status: Int?) -> String {
        let msg = message ?? ""
        if status == 401 || type == "authentication_error" {
            return "Ключ API не підходить. Перевір його в меню ⚙︎ → «Ключ Claude API»."
        }
        if status == 403 || type == "permission_error" {
            return "Цей ключ не має доступу до вибраної моделі."
        }
        if msg.localizedCaseInsensitiveContains("credit balance") {
            return "На рахунку API закінчились кошти. Поповни баланс на console.anthropic.com."
        }
        if status == 429 || type == "rate_limit_error" {
            return "Забагато запитів поспіль. Спробуй за хвилину."
        }
        if status == 529 || type == "overloaded_error" {
            return "Claude зараз перевантажений. Спробуй трохи згодом."
        }
        if let s = status, s >= 500 {
            return "Проблема на боці сервера Claude (\(s)). Спробуй ще раз."
        }
        return msg.isEmpty ? "Невідома помилка." : "Помилка: \(msg)"
    }

    /// Пояснення причини зупинки, якщо вона незвична.
    public static func stopNote(_ reason: String) -> String? {
        switch reason {
        case "refusal": return "Claude відмовився відповідати на це питання."
        case "max_tokens": return "Відповідь обрізано — вона задовга."
        default: return nil
        }
    }

    /// Посилання, що відкриває нову розмову в застосунку Claude з уже вписаним питанням.
    public static func desktopURL(prompt: String) -> URL? {
        var c = URLComponents()
        c.scheme = "claude"
        c.host = "claude.ai"
        c.path = "/new"
        c.queryItems = [URLQueryItem(name: "q", value: prompt)]
        // «+» у запиті часто читається як пробіл — кодуємо явно («C++» лишиться «C++»).
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url
    }
}
