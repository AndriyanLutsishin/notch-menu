import Foundation

/// Програма для швидкого відкриття з лічильником пропущених (число з іконки в Dock).
public struct QuickApp: Identifiable, Sendable, Equatable {
    public let id: String          // bundle id
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public static let messengers: [QuickApp] = [
        QuickApp(id: "ru.keepcoder.Telegram", name: "Telegram"),
        QuickApp(id: "com.viber.osx", name: "Viber"),
        QuickApp(id: "net.whatsapp.WhatsApp", name: "WhatsApp"),
    ]
}

public enum BadgeParser {
    /// Розбирає вивід `lsappinfo info -only StatusLabel ...`.
    /// Приклад рядка з числом: `"StatusLabel"={ "label"="3" }`. Порожньо — немає пропущених.
    public static func parse(_ output: String) -> String? {
        guard let range = output.range(of: #""label"="([^"]*)""#, options: .regularExpression) else { return nil }
        let match = output[range]
        let value = match.replacingOccurrences(of: #""label"=""#, with: "", options: .regularExpression)
            .dropLast()
        let label = String(value).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }
}
