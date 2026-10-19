import Foundation

/// Один запис історії буфера обміну.
public struct ClipItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let copiedAt: Date
    public let sourceApp: String?
    public let sourceBundleID: String?

    public init(id: UUID = UUID(), text: String, copiedAt: Date, sourceApp: String?, sourceBundleID: String? = nil) {
        self.id = id
        self.text = text
        self.copiedAt = copiedAt
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
    }

    public var kind: ClipKind { ClipKind.detect(text) }
}

/// Що саме скопійовано — для значка й кольору картки.
public enum ClipKind: Equatable, Sendable {
    case link(host: String)
    case email
    case phone
    case number
    case code
    case text

    public var title: String {
        switch self {
        case .link: return "Посилання"
        case .email: return "Пошта"
        case .phone: return "Телефон"
        case .number: return "Число"
        case .code: return "Код"
        case .text: return "Текст"
        }
    }

    public var icon: String {
        switch self {
        case .link: return "link"
        case .email: return "envelope"
        case .phone: return "phone"
        case .number: return "number"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .text: return "text.alignleft"
        }
    }

    public static func detect(_ raw: String) -> ClipKind {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneLine = !t.contains("\n")
        if oneLine, !t.contains(" "), let url = URL(string: t), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), let host = url.host {
            return .link(host: host.replacingOccurrences(of: "www.", with: ""))
        }
        if oneLine, t.range(of: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil {
            return .email
        }
        if oneLine, isPhone(t) { return .phone }
        if oneLine, t.range(of: #"^[-+]?[0-9 ]*[0-9]([.,][0-9]+)?$"#, options: .regularExpression) != nil { return .number }
        let codeHints = ["{", "};", "func ", "def ", "const ", "import ", "</", "=>", "#include", "SELECT "]
        if codeHints.contains(where: { t.contains($0) }) && (t.contains("\n") || t.contains(";") || t.contains("{")) {
            return .code
        }
        return .text
    }

    /// Телефон: 10–13 цифр, починається з «+», «0» або «380», і це не дата.
    static func isPhone(_ t: String) -> Bool {
        guard t.range(of: #"^\+?[0-9][0-9 ()\-]{8,}$"#, options: .regularExpression) != nil,
              t.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) == nil else { return false }
        let digits = t.filter(\.isNumber)
        guard (10...13).contains(digits.count) else { return false }
        return t.hasPrefix("+") || digits.hasPrefix("0") || digits.hasPrefix("380")
    }
}


/// Історія скопійованого тексту за останню годину.
/// Живе лише в пам'яті: нічого не пишеться на диск.
public final class ClipboardHistory {
    /// Скільки живе запис (60 хв).
    public static let maxAge: TimeInterval = 60 * 60
    /// Дуже великі тексти не зберігаємо, щоб не роздувати пам'ять.
    public static let maxTextLength = 200_000

    public let maxItems: Int
    private let now: () -> Date
    private var storage: [ClipItem] = []  // новіші на початку

    /// `now` можна підмінити в тестах, щоб «прискорити» час.
    public init(maxItems: Int = 300, now: @escaping () -> Date = Date.init) {
        self.maxItems = maxItems
        self.now = now
    }

    /// Усі живі записи (старші за годину спершу видаляються).
    public var items: [ClipItem] {
        prune()
        return storage
    }

    /// Додає текст нагору. Якщо такий текст уже є — просто піднімає його.
    @discardableResult
    public func add(_ text: String, sourceApp: String? = nil, sourceBundleID: String? = nil) -> Bool {
        prune()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= Self.maxTextLength else { return false }
        storage.removeAll { $0.text == text }
        storage.insert(ClipItem(text: text, copiedAt: now(), sourceApp: sourceApp, sourceBundleID: sourceBundleID), at: 0)
        if storage.count > maxItems {
            storage.removeLast(storage.count - maxItems)
        }
        return true
    }

    /// Видаляє все, що старше за годину. Повертає, чи щось видалилось.
    @discardableResult
    public func prune() -> Bool {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        let before = storage.count
        storage.removeAll { $0.copiedAt <= cutoff }
        return storage.count != before
    }

    /// Пошук без урахування регістру.
    public func search(_ query: String) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = items
        guard !q.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    public func clear() {
        storage.removeAll()
    }
}
