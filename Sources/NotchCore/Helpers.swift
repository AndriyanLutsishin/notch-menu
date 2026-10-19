import Foundation

// MARK: - 1. Виправлення розкладки (англійська ⇄ українська)

public enum LayoutFix {
    /// Клавіші англійської розкладки → та сама клавіша в українській (macOS «Українська»).
    private static let enToUk: [Character: Character] = {
        // Розкладка «Українська (ПК)»: літери + символи на Shift-цифрах (@#$^& → "№;:?).
        let en = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,./`\\QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?~|@#$^&")
        let uk = Array("йцукенгшщзхїфівапролджєячсмитьбю.'ґЙЦУКЕНГШЩЗХЇФІВАПРОЛДЖЄЯЧСМИТЬБЮ,₴Ґ\"№;:?")
        var map: [Character: Character] = [:]
        for (a, b) in zip(en, uk) { map[a] = b }
        return map
    }()

    private static let ukToEn: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (a, b) in enToUk where map[b] == nil { map[b] = a }
        return map
    }()

    /// Сам визначає напрямок: більше латиниці — перекладаємо в українську, і навпаки.
    public static func convert(_ text: String) -> String {
        let latin = text.unicodeScalars.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count
        let cyrillic = text.unicodeScalars.filter { (0x0400...0x04FF).contains(Int($0.value)) }.count
        let map = latin >= cyrillic ? enToUk : ukToEn
        return String(text.map { map[$0] ?? $0 })
    }
}

// MARK: - 2. «Розумні» дії для скопійованого

public enum SmartAction: Equatable, Sendable {
    case open(URL)
    case call(String)
    case maps(String)
    case track(String)
    case compactIBAN(String)
    case mail(String)

    public var title: String {
        switch self {
        case .open: return "Відкрити"
        case .call: return "Подзвонити"
        case .maps: return "У Картах"
        case .track: return "Відстежити"
        case .compactIBAN: return "Без пробілів"
        case .mail: return "Написати"
        }
    }

    public var icon: String {
        switch self {
        case .open: return "safari"
        case .call: return "phone.fill"
        case .maps: return "map"
        case .track: return "shippingbox"
        case .compactIBAN: return "creditcard"
        case .mail: return "envelope"
        }
    }

    /// Що відкрити (для «Без пробілів» — нічого, лише скопіювати).
    public var url: URL? {
        switch self {
        case .open(let u): return u
        case .call(let p): return URL(string: "tel:" + p.filter { $0.isNumber || $0 == "+" })
        case .maps(let a):
            var c = URLComponents(string: "maps://")!
            c.queryItems = [URLQueryItem(name: "q", value: a)]
            return c.url
        case .track(let n): return URL(string: "https://novaposhta.ua/tracking/?cargo_number=\(n)")
        case .mail(let e): return URL(string: "mailto:\(e)")
        case .compactIBAN: return nil
        }
    }

    public var copyText: String? {
        if case .compactIBAN(let i) = self { return i }
        return nil
    }

    /// «20261019153000» — це дата й час (рррρММддггххсс), а не ТТН.
    static func looksLikeTimestamp(_ d: String) -> Bool {
        let n = d.compactMap { $0.wholeNumberValue }
        guard n.count == 14 else { return false }
        func num(_ a: Int, _ len: Int) -> Int { n[a..<(a + len)].reduce(0) { $0 * 10 + $1 } }
        let (y, mo, day, h, mi, se) = (num(0, 4), num(4, 2), num(6, 2), num(8, 2), num(10, 2), num(12, 2))
        return (2000...2099).contains(y) && (1...12).contains(mo) && (1...31).contains(day) && h < 24 && mi < 60 && se < 60
    }

    public static func detect(_ raw: String) -> SmartAction? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 400 else { return nil }
        let compact = t.replacingOccurrences(of: " ", with: "").uppercased()
        // IBAN України: UA + 27 цифр.
        if compact.range(of: #"^UA\d{27}$"#, options: .regularExpression) != nil { return .compactIBAN(compact) }
        // ТТН Нової пошти: 14 цифр, починається на 59 або 20.
        let digits = t.filter(\.isNumber)
        if digits.count == 14, t.filter({ !$0.isNumber && $0 != " " }).isEmpty,
           digits.hasPrefix("59") || digits.hasPrefix("20"), !looksLikeTimestamp(digits) { return .track(digits) }
        if case .email = ClipKind.detect(t) { return .mail(t) }
        if case .link = ClipKind.detect(t), let u = URL(string: t) { return .open(u) }
        if case .phone = ClipKind.detect(t) { return .call(t) }
        // Адреса — системний розпізнавач (працює локально).
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue),
           let m = detector.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           m.range.length >= t.count / 2 {
            return .maps(t)
        }
        return nil
    }
}

// MARK: - 5. Калькулятор із валютою

public enum Calculator {
    public struct Result: Equatable, Sendable {
        public let value: Double
        /// Код валюти виразу (840, 978, 985, 980) або nil — просте число.
        public let currency: Int?
    }

    /// Рахує «120$ + 15%», «(250+50)*3», «1 200,50 грн / 4». nil — якщо це не вираз.
    public static func evaluate(_ raw: String) -> Result? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count < 120 else { return nil }
        // Дати не рахуємо: «2026-10-19», «19.10.2026».
        if s.range(of: #"^\d{4}-\d{1,2}(-\d{1,2})?$"#, options: .regularExpression) != nil
            || s.range(of: #"^\d{1,2}[./]\d{1,2}([./]\d{2,4})?$"#, options: .regularExpression) != nil
            || s.range(of: #"^\d+([.,]\d+)?\s*%$"#, options: .regularExpression) != nil { return nil }
        var codes = Set<Int>()
        let words: [(String, Int)] = [("грн", 980), ("₴", 980), ("uah", 980), ("$", 840), ("usd", 840), ("дол", 840),
                                      ("€", 978), ("eur", 978), ("євро", 978), ("zł", 985), ("pln", 985), ("зл", 985)]
        for (w, code) in words where s.contains(w) {
            codes.insert(code)
            s = s.replacingOccurrences(of: w, with: "")
        }
        // Різні валюти в одному виразі не додаємо — незрозуміло, що мається на увазі.
        guard codes.count <= 1 else { return nil }
        let currency = codes.first
        s = s.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "x", with: "*")
        let allowed = Set("0123456789+-*/()%., \u{00a0}\u{202f}")
        guard s.allSatisfy({ allowed.contains($0) }), s.contains(where: \.isNumber) else { return nil }
        // Потрібна хоч якась дія або валюта, інакше це просто число.
        let hasOp = s.dropFirst().contains { "+-*/%".contains($0) }
        guard hasOp || currency != nil else { return nil }
        var p = Parser(Array(s.filter { $0 != " " && $0 != "\u{00a0}" && $0 != "\u{202f}" }))
        guard let v = p.expression(), p.atEnd, v.isFinite else { return nil }
        return Result(value: v, currency: currency)
    }

    private struct Parser {
        let c: [Character]
        var i = 0
        init(_ c: [Character]) { self.c = c }
        var atEnd: Bool { i >= c.count }
        func peek() -> Character? { i < c.count ? c[i] : nil }

        /// a + b% означає «a плюс b відсотків від a».
        mutating func expression() -> Double? {
            guard var left = term()?.value else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                i += 1
                guard let right = term() else { return nil }
                let delta = right.percent ? left * right.value / 100 : right.value
                left = op == "+" ? left + delta : left - delta
            }
            return left
        }

        mutating func term() -> (value: Double, percent: Bool)? {
            guard var first = factor() else { return nil }
            var value = first.value
            var percent = first.percent
            while let op = peek(), op == "*" || op == "/" {
                if percent { value /= 100; percent = false }  // «50% * 200» = 100
                i += 1
                guard let f = factor() else { return nil }
                let rhs = f.percent ? f.value / 100 : f.value
                if op == "*" { value *= rhs } else { guard rhs != 0 else { return nil }; value /= rhs }
                percent = false
                first = (value, false)
            }
            return (value, percent)
        }

        mutating func factor() -> (value: Double, percent: Bool)? {
            var v: Double
            if peek() == "-" { i += 1; guard let f = factor() else { return nil }; return (-f.value, f.percent) }
            if peek() == "(" {
                i += 1
                guard let e = expression(), peek() == ")" else { return nil }
                i += 1
                v = e
            } else {
                var digits = ""
                while let ch = peek(), ch.isNumber || ch == "." || ch == "," { digits.append(ch == "," ? "." : ch); i += 1 }
                guard let d = Double(digits) else { return nil }
                v = d
            }
            if peek() == "%" { i += 1; return (v, true) }
            return (v, false)
        }
    }

    public static func format(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{00a0}"
        f.decimalSeparator = ","
        f.maximumFractionDigits = 2
        f.roundingMode = .halfUp
        f.minimumFractionDigits = v.rounded() == v ? 0 : 2
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

// MARK: - 4. Шаблони повідомлень (файл програми на цьому Mac)

public struct Template: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public init(id: UUID = UUID(), text: String) { self.id = id; self.text = text }
    public var title: String { text.split(separator: "\n").first.map(String.init) ?? text }
}

public final class TemplateStore {
    public private(set) var items: [Template] = []
    private let fileURL: URL

    public static var defaultURL: URL {
        ReminderStore.defaultURL.deletingLastPathComponent().appendingPathComponent("templates.json")
    }

    public init(fileURL: URL = TemplateStore.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            if let list = try? JSONDecoder().decode([Template].self, from: data) { items = list }
            else { SafeFile.backUpUnreadable(fileURL) }  // не затираємо файл, який не змогли прочитати
        }
    }

    @discardableResult
    public func add(_ raw: String) -> Template? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = String(text.prefix(2000))
        guard !text.isEmpty, !items.contains(where: { $0.text == stored }) else { return nil }
        let t = Template(text: stored)
        items.insert(t, at: 0)
        save()
        return t
    }

    public func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: fileURL, options: .atomic) }
    }
}

// MARK: - 8. Бюджет на день

public enum Budget {
    public struct Day: Equatable, Sendable {
        public let spentMonth: Int     // копійки
        public let spentToday: Int
        public let allowanceToday: Int // скільки можна було на сьогодні
        public var leftToday: Int { allowanceToday - spentToday }
        /// 0 — норм, 1 — майже вичерпано, 2 — перевищено.
        public var level: Int { spentToday > allowanceToday ? 2 : (Double(spentToday) > Double(allowanceToday) * 0.8 ? 1 : 0) }
    }

    /// monthly — у гривнях; витрати — від'ємні суми операцій цього місяця.
    public static func compute(monthly: Int, transactions: [Monobank.Transaction], now: Date = Date(),
                               calendar: Calendar = .current) -> Day? {
        guard monthly > 0, let month = calendar.dateInterval(of: .month, for: now) else { return nil }
        let startToday = calendar.startOfDay(for: now)
        var spentMonth = 0, spentBefore = 0, spentToday = 0
        for t in transactions where t.amount < 0 && t.date >= month.start && t.date < month.end {
            spentMonth += -t.amount
            if t.date >= startToday { spentToday += -t.amount } else { spentBefore += -t.amount }
        }
        let daysLeft = max(1, (calendar.dateComponents([.day], from: startToday, to: month.end).day ?? 1))
        let allowance = max(0, (monthly * 100 - spentBefore) / daysLeft)
        return Day(spentMonth: spentMonth, spentToday: spentToday, allowanceToday: allowance)
    }
}

/// Якщо файл даних не читається (пошкоджений чи з новішої версії) — відкладаємо його в .bak, а не затираємо.
enum SafeFile {
    static func backUpUnreadable(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.deletingPathExtension().appendingPathExtension("bak-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
