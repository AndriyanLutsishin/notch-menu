import AppKit
import ApplicationServices

/// Читає червоні числа (пропущені) з іконок у Dock.
/// Потрібен дозвіл «Універсальний доступ» — лише для читання цих чисел, нічого більше.
enum DockBadges {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Показує системний запит і відкриває потрібний розділ Системних параметрів.
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// [шлях до програми: число з іконки]
    static func read() -> [String: String] {
        guard isTrusted,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var result: [String: String] = [:]
        for list in children(of: app) {
            for item in children(of: list) {
                guard let label = attribute(item, "AXStatusLabel") as? String, !label.isEmpty else { continue }
                if let url = attribute(item, kAXURLAttribute) as? URL {
                    result[url.standardizedFileURL.path] = label
                } else if let url = attribute(item, kAXURLAttribute).flatMap({ $0 as? NSURL }) as URL? {
                    result[url.standardizedFileURL.path] = label
                }
            }
        }
        return result
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
