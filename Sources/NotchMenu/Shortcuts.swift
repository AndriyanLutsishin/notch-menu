import AppKit
import Carbon.HIToolbox

/// Глобальна комбінація клавіш (код клавіші + модифікатори Carbon) і її підпис «⌃⌥C».
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    var label: String

    static let panelDefault = Shortcut(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey, label: "⌃⌥C")
    static let layoutDefault = Shortcut(keyCode: kVK_ANSI_L, modifiers: controlKey | optionKey, label: "⌃⌥L")

    /// Із натискання клавіш; nil — якщо немає ⌘, ⌃ чи ⌥ (інакше заважало б звичайному набору).
    static func from(event: NSEvent) -> Shortcut? {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard f.contains(.command) || f.contains(.control) || f.contains(.option) else { return nil }
        var mods = 0
        var label = ""
        if f.contains(.control) { mods |= controlKey; label += "⌃" }
        if f.contains(.option) { mods |= optionKey; label += "⌥" }
        if f.contains(.shift) { mods |= shiftKey; label += "⇧" }
        if f.contains(.command) { mods |= cmdKey; label += "⌘" }
        let code = Int(event.keyCode)
        guard let key = keyName(code) else { return nil }
        return Shortcut(keyCode: code, modifiers: mods, label: label + key)
    }

    /// Назва клавіші за її місцем на клавіатурі (не залежить від розкладки).
    static func keyName(_ code: Int) -> String? {
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
            kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
            kVK_Space: "Пробіл", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return letters[code]
    }
}

/// Дії, яким можна призначити свою комбінацію.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case panel, layout
    var id: String { rawValue }

    var title: String {
        switch self {
        case .panel: return "Відкрити / закрити панель"
        case .layout: return "Виправити розкладку виділеного"
        }
    }

    var help: String {
        switch self {
        case .panel: return "Працює в будь-якій програмі. Те саме, що навести курсор на чубчик."
        case .layout: return "Виділи текст, набраний не тією розкладкою («ghbdsn»), і натисни — стане «привіт»."
        }
    }

    var defaultShortcut: Shortcut { self == .panel ? .panelDefault : .layoutDefault }
    var storageKey: String { "shortcut.\(rawValue)" }
}
