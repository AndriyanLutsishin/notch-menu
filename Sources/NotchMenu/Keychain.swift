import Foundation
import Security

/// Ключі зберігаються лише у «Зв'язці ключів» macOS — ніколи у файлах чи коді.
enum Keychain {
    private static let account = "default"

    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String, service: String, label: String) -> Bool {
        // Спершу оновлюємо наявний запис — щоб не втратити старий ключ, якщо щось піде не так.
        let update = [kSecValueData as String: Data(value.utf8)] as CFDictionary
        let status = SecItemUpdate(query(service) as CFDictionary, update)
        if status == errSecSuccess { return true }
        var q = query(service)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrLabel as String] = label
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        var added = SecItemAdd(q as CFDictionary, nil)
        if added == errSecDuplicateItem {  // старий запис є, але оновити не дали — лише тоді замінюємо
            delete(service: service)
            added = SecItemAdd(q as CFDictionary, nil)
        }
        return added == errSecSuccess
    }

    static func read(service: String) -> String? {
        var q = query(service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Перевіряє наявність без читання самого секрету (не викликає запитів пароля).
    static func exists(service: String) -> Bool {
        var q = query(service)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    @discardableResult
    static func delete(service: String) -> Bool {
        SecItemDelete(query(service) as CFDictionary) == errSecSuccess
    }
}
