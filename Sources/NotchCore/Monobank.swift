import Foundation

/// Особистий API монобанку — лише читання (баланс і виписка). Гроші ним переказати неможливо.
public enum Monobank {
    public static let base = URL(string: "https://api.monobank.ua")!
    /// Монобанк дозволяє один запит на хвилину.
    public static let cooldown: TimeInterval = 60

    public struct ClientInfo: Decodable, Equatable, Sendable {
        public let name: String?
        public let accounts: [Account]
        public let jars: [Jar]?
    }

    public struct Account: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let balance: Int
        public let creditLimit: Int
        public let currencyCode: Int
        public let type: String?
        public let maskedPan: [String]?

        public var ownMoney: Int { balance - creditLimit }

        public var title: String {
            let kind: String
            switch type {
            case "black": kind = "Чорна"
            case "white": kind = "Біла"
            case "platinum": kind = "Platinum"
            case "iron": kind = "Iron"
            case "fop": kind = "ФОП"
            case "yellow": kind = "Дитяча"
            case "eAid": kind = "єПідтримка"
            default: kind = "Рахунок"
            }
            if let pan = maskedPan?.first, pan.count >= 4 {
                return "\(kind) ··\(pan.suffix(4))"
            }
            return kind
        }
    }

    public struct Jar: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let balance: Int
        public let currencyCode: Int
        public let goal: Int?

        /// Наскільки наповнена банка (0…1), якщо є ціль.
        public var progress: Double? {
            guard let goal, goal > 0 else { return nil }
            return min(1, Double(balance) / Double(goal))
        }
    }

    public struct Transaction: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let time: Int
        public let description: String
        public let amount: Int
        public let currencyCode: Int
        public let hold: Bool?
        public let mcc: Int?

        /// Значок категорії, як кружечки в застосунку монобанку.
        public var icon: String { Monobank.icon(mcc: mcc, amount: amount) }

        public var date: Date { Date(timeIntervalSince1970: TimeInterval(time)) }
    }

    /// Категорія операції за кодом MCC → емодзі.
    public static func icon(mcc: Int?, amount: Int) -> String {
        if amount > 0 { return "💰" }
        switch mcc ?? 0 {
        case 5411, 5412, 5422, 5441, 5451, 5462, 5499: return "🛒"
        case 5811, 5812, 5813, 5814: return "🍔"
        case 4111, 4112, 4121, 4131, 4789: return "🚕"
        case 5541, 5542, 5172: return "⛽"
        case 5912, 8011, 8021, 8062, 8099: return "💊"
        case 4829, 6012, 6538, 6540: return "💸"
        case 6010, 6011: return "🏧"
        case 4814, 4899: return "📱"
        case 4900: return "💡"
        case 5611, 5621, 5631, 5651, 5661, 5691, 5699: return "👕"
        case 5732, 5734, 5735, 5815, 5816, 5817, 5818: return "🎬"
        case 7832, 7922, 7991, 7996: return "🎟️"
        case 5311, 5331, 5399, 5999: return "🛍️"
        case 4511, 3000...3299, 7011: return "✈️"
        default: return "💳"
        }
    }

    public static func request(path: String, token: String) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.setValue(token, forHTTPHeaderField: "X-Token")
        r.timeoutInterval = 30
        return r
    }

    public static func clientInfoRequest(token: String) -> URLRequest {
        request(path: "personal/client-info", token: token)
    }

    /// Виписка від дати `from` (не раніше ніж 31 день тому — обмеження монобанку).
    public static func statementRequest(token: String, account: String, from: Date, now: Date = Date()) -> URLRequest {
        let to = Int(now.timeIntervalSince1970)
        let earliest = to - (31 * 24 + 1) * 3600  // ліміт монобанку: 31 доба + 1 година
        let start = max(Int(from.timeIntervalSince1970), earliest)
        return request(path: "personal/statement/\(account)/\(start)/\(to)", token: token)
    }

    /// Виписка за останні `days` днів (монобанк дозволяє максимум 31 день).
    public static func statementRequest(token: String, account: String, days: Int = 7, now: Date = Date()) -> URLRequest {
        let to = Int(now.timeIntervalSince1970)
        let from = to - min(days, 31) * 24 * 3600
        return request(path: "personal/statement/\(account)/\(from)/\(to)", token: token)
    }

    /// Головна гривнева картка: спершу чорна, інакше будь-яка в гривні.
    public static func mainAccount(_ accounts: [Account]) -> Account? {
        accounts.first { $0.currencyCode == 980 && $0.type == "black" }
            ?? accounts.first { $0.currencyCode == 980 }
            ?? accounts.first
    }

    public static func currencySymbol(_ code: Int) -> String {
        switch code {
        case 980: return "₴"
        case 840: return "$"
        case 978: return "€"
        case 826: return "£"
        case 985: return "zł"
        default: return "(\(code))"
        }
    }

    /// Сума в копійках → «1 234,56 ₴».
    public static func formatMoney(_ minor: Int, currency: Int, showPlus: Bool = false) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "uk_UA")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.groupingSeparator = "\u{00a0}"  // нерозривний пробіл: «1 234,56»
        f.decimalSeparator = ","
        let value = Double(minor) / 100
        let body = f.string(from: NSNumber(value: abs(value))) ?? String(format: "%.2f", abs(value))
        let sign = minor < 0 ? "−" : (showPlus && minor > 0 ? "+" : "")
        return "\(sign)\(body) \(currencySymbol(currency))"
    }

    public static func friendlyError(status: Int) -> String {
        switch status {
        case 401, 403: return "Токен монобанку не підходить. Створи новий на api.monobank.ua."
        case 429: return "Монобанк дозволяє оновлювати дані раз на хвилину. Зачекай трохи."
        default: return "Монобанк не відповів (код \(status)). Спробуй пізніше."
        }
    }
}
