import Foundation

/// Питання до Claude через Claude Code, вбудований у застосунок Claude desktop.
/// Працює через підписку claude.ai — ключ API не потрібен.
public enum ClaudeCode {
    /// Де шукати програму `claude` (новіша версія — першою).
    public static func findExecutable(home: String = NSHomeDirectory(), fm: FileManager = .default) -> String? {
        let base = "\(home)/Library/Application Support/Claude/claude-code"
        var bundled: [String] = []
        if let versions = try? fm.contentsOfDirectory(atPath: base) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                if let builds = try? fm.contentsOfDirectory(atPath: "\(base)/\(v)") {
                    for b in builds { bundled.append("\(base)/\(v)/\(b)/claude.app/Contents/MacOS/claude") }
                }
            }
        }
        let others = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                      "\(home)/.npm-global/bin/claude", "\(home)/.claude/local/claude"]
        return (bundled + others).first { fm.isExecutableFile(atPath: $0) }
    }

    /// Аргументи: без інструментів, без збереження сесії, без плагінів і хуків користувача.
    public static func arguments(model: AskProvider) -> [String] {
        ["-p", "--model", model.rawValue, "--effort", "low",
         "--tools", "", "--no-session-persistence", "--strict-mcp-config",
         "--disable-slash-commands", "--setting-sources", "project",
         "--system-prompt", ClaudeAPI.systemPrompt,
         "--output-format", "stream-json", "--include-partial-messages", "--verbose"]
    }

    /// Розбирає один рядок потоку `stream-json`.
    public static func parseLine(_ line: String) -> ClaudeAPI.StreamEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        switch type {
        case "stream_event":
            guard let event = json["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .text(text)
        case "result":
            if json["is_error"] as? Bool == true {
                return .error(friendlyError(json["result"] as? String ?? (json["subtype"] as? String ?? "")))
            }
            return .stop(reason: "end_turn")
        default:
            return nil
        }
    }

    public static func friendlyError(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("login") || s.contains("not logged") || s.contains("invalid api key") || s.contains("oauth") {
            return "Claude не залогінений. Відкрий застосунок Claude і увійди у свій акаунт."
        }
        if s.contains("usage limit") || s.contains("limit reached") || s.contains("rate limit") {
            return "Вичерпано ліміт підписки Claude. Спробуй пізніше."
        }
        if s.contains("model") && (s.contains("not available") || s.contains("not found") || s.contains("access")) {
            return "Ця модель недоступна у твоїй підписці. Обери іншу."
        }
        return raw.isEmpty ? "Claude не відповів." : "Помилка Claude: \(raw)"
    }
}
