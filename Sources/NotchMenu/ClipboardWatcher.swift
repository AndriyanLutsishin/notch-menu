import AppKit
import NotchCore

/// Стежить за буфером обміну: раз на пів секунди дивиться, чи щось скопіювали.
@MainActor
final class ClipboardWatcher {
    private let onText: (String, String?, String?) -> Void
    /// Якщо «Буфер» сховано в налаштуваннях — історію не ведемо зовсім.
    var isEnabled: () -> Bool = { true }
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var suppressedUntil = Date.distantPast

    /// Тимчасово не записувати зміни буфера (коли ми самі копіюємо службовий текст).
    func suppress(seconds: TimeInterval) { suppressedUntil = Date().addingTimeInterval(seconds) }

    init(onText: @escaping (String, String?, String?) -> Void) {
        self.onText = onText
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 0.15
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard Date() >= suppressedUntil, isEnabled() else { return }

        let types = pb.types?.map(\.rawValue) ?? []
        let front = NSWorkspace.shared.frontmostApplication
        // Спершу перевіряємо типи й програму-джерело — секрет навіть не читаємо.
        guard !PasteboardPolicy.shouldSkip(types: types, sourceBundleID: front?.bundleIdentifier) else {
            Debug.log("буфер: пропущено (прихований тип або менеджер паролів)")
            return
        }
        guard types.contains(NSPasteboard.PasteboardType.string.rawValue) else { return }

        let sourceID = pb.string(forType: .init(PasteboardPolicy.sourceType))
        guard !PasteboardPolicy.isPasswordManager(sourceID),
              let text = pb.string(forType: .string),
              !PasteboardPolicy.looksLikeSecret(text) else {
            Debug.log("буфер: пропущено (схоже на ключ/пароль)")
            return
        }

        Debug.log("буфер: додано текст з \(text.count) символів з \(front?.localizedName ?? "?")")
        onText(text, front?.localizedName, front?.bundleIdentifier)
    }
}
