import AppKit
import ApplicationServices
import Carbon.HIToolbox
import NotchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var panel: PanelController!
    private var hover: HoverWatcher!
    private var clipboard: ClipboardWatcher!
    private var hotKey: HotKey?
    private var layoutHotKey: HotKey?
    private var callWatcher: CallWatcher?
    private let warnings = WarningIndicator()
    private var warningTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Без меню «Редагування» не працюють ⌘V / ⌘C / ⌘A у полях вводу.
        NSApp.mainMenu = Self.makeMainMenu()

        model = AppModel()
        panel = PanelController(model: model)
        model.onRequestClose = { [weak self] in self?.panel.close() }
        model.onTimerFinished = { [weak self] in self?.panel.flash(seconds: 8) }

        // Попередження біля чубчика (перегрів, слабка батарея).
        warnings.onClick = { [weak self] in
            guard let self else { return }
            self.model.tab = .system
            self.panel.toggleFromHotKey()
        }
        model.system.startBackground()
        warningTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.warnings.update(warning: self.model.system.warning, panelOpen: self.panel.isOpen)
            }
        }
        warningTimer?.tolerance = 0.5

        clipboard = ClipboardWatcher { [weak self] text, source, bundleID in
            self?.model.addClip(text, source: source, bundleID: bundleID)
        }
        clipboard.isEnabled = { [weak self] in self?.model.isShown(.clips) ?? true }
        clipboard.start()

        hover = HoverWatcher(panel: panel)
        hover.start()

        // Гарячі клавіші (за замовчуванням ⌃⌥C і ⌃⌥L; змінюються в налаштуваннях). Без дозволів macOS.
        model.onShortcutsChanged = { [weak self] in self?.registerHotKeys() }
        registerHotKeys()
        callWatcher = CallWatcher(player: model.nowPlaying)
        callWatcher?.start()

        Debug.log("Універсальний доступ: \(AXIsProcessTrusted() ? "так" : "ні")")
        if #available(macOS 15.4, *) {
            Debug.log("доступ до буфера: \(NSPasteboard.general.accessBehavior.rawValue) (0 — спитає, 2 — дозволено, 3 — заборонено)")
        }
        if let dir = Debug.snapshotDir {
            Debug.runSnapshots(panel: panel, model: model, to: dir)
            return
        }

        // Аргументи для перевірки: `open NotchMenu.app --args --open clips`
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--ask"), i + 2 < args.count, let p = AskProvider(rawValue: args[i + 1]) {
            model.provider = p
            model.prompt = args[i + 2]
            panel.toggleFromHotKey()
            model.ask()
            return
        }
        if let i = args.firstIndex(of: "--open") {
            if i + 1 < args.count, let tab = AppModel.Tab(rawValue: args[i + 1]) { model.tab = tab }
            panel.toggleFromHotKey()
        } else if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            panel.toggleFromHotKey()  // перший запуск — одразу показати панель
        }
    }

    /// (Пере)реєструє глобальні комбінації. Поки записується нова — усі вимкнено.
    private func registerHotKeys() {
        hotKey = nil
        layoutHotKey = nil
        guard model.recordingShortcut == nil else { return }
        let panelKey = model.shortcut(.panel)
        hotKey = HotKey(keyCode: panelKey.keyCode, modifiers: panelKey.modifiers, number: 1) { [weak self] in
            self?.panel.toggleFromHotKey()
        }
        let layoutKey = model.shortcut(.layout)
        layoutHotKey = HotKey(keyCode: layoutKey.keyCode, modifiers: layoutKey.modifiers, number: 2) { [weak self] in
            guard let self else { return }
            SelectionLayoutFixer.run(clipboard: self.clipboard)
        }
        var conflicts: Set<ShortcutAction> = []
        if hotKey == nil { conflicts.insert(.panel) }
        if layoutHotKey == nil { conflicts.insert(.layout) }
        model.shortcutConflicts = conflicts
        model.hotKeyNote = conflicts.contains(.panel)
            ? "Комбінацію \(panelKey.label) зайняла інша програма — зміни її в ⚙︎ → «Комбінації клавіш»." : nil
    }

    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Вийти з Notch Menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Редагування")
        edit.addItem(withTitle: "Скасувати", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторити", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вирізати", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копіювати", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставити", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Виділити все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
