import Foundation

// MARK: - Курс валют монобанку (відкриті дані, без токена)

public enum MonoCurrency {
    public static let url = URL(string: "https://api.monobank.ua/bank/currency")!
    /// Монобанк оновлює курс нечасто й обмежує запити — тримаємо в пам'яті 10 хв.
    public static let cacheTime: TimeInterval = 10 * 60

    public struct Rate: Decodable, Equatable, Sendable, Identifiable {
        public let currencyCodeA: Int
        public let currencyCodeB: Int
        public let rateBuy: Double?
        public let rateSell: Double?
        public let rateCross: Double?
        public var id: Int { currencyCodeA }

        /// Курс продажу (скільки гривень коштує 1 одиниця валюти).
        public var sell: Double? { rateSell ?? rateCross }
    }

    /// Долар, євро, злотий — до гривні, саме в такому порядку.
    public static func pick(_ all: [Rate]) -> [Rate] {
        [840, 978, 985].compactMap { code in all.first { $0.currencyCodeA == code && $0.currencyCodeB == 980 } }
    }

    public static func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - Таймер / Pomodoro

public enum FocusTimer {
    public static let presets: [(minutes: Int, title: String)] = [
        (25, "Pomodoro · 25 хв"), (5, "Перерва · 5 хв"), (15, "Довга перерва · 15 хв"), (45, "Фокус · 45 хв"),
    ]

    /// Скільки лишилось → «24:13» або «1:02:03».
    public static func format(remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Попередження

public enum SystemWarning: Equatable, Sendable {
    case hot(Int)
    case lowBattery(Int)

    public var text: String {
        switch self {
        case .hot(let t): return "🔥 \(t)°"
        case .lowBattery(let p): return "🪫 \(p)%"
        }
    }

    /// Перегрів — від 90 °C або коли macOS сама каже «гаряче»; батарея — до 15% і без зарядки.
    public static func evaluate(cpu: Double?, thermalSerious: Bool, battery: Int?, charging: Bool) -> SystemWarning? {
        if let cpu, cpu >= 90 || thermalSerious { return .hot(Int(cpu.rounded())) }
        if thermalSerious { return .hot(0) }
        if let battery, battery <= 15, !charging { return .lowBattery(battery) }
        return nil
    }
}

// MARK: - Дії Claude над скопійованим текстом

public enum ClipAction: String, CaseIterable, Identifiable, Sendable {
    case translate, rewrite, explain

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .translate: return "Переклади"
        case .rewrite: return "Перепиши"
        case .explain: return "Поясни"
        }
    }

    public var icon: String {
        switch self {
        case .translate: return "globe"
        case .rewrite: return "pencil.line"
        case .explain: return "lightbulb"
        }
    }

    public func prompt(for text: String) -> String {
        let instruction: String
        switch self {
        case .translate:
            instruction = "Переклади текст нижче. Якщо він українською — на англійську, інакше — на українську. Дай лише переклад."
        case .rewrite:
            instruction = "Перепиши текст нижче грамотно, ввічливо й зрозуміло, тією ж мовою. Дай лише результат."
        case .explain:
            instruction = "Поясни простими словами, що означає текст нижче (українською, коротко)."
        }
        return "\(instruction)\n\n\(text)"
    }
}
