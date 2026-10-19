import AppKit

/// Інструменти для самоперевірки (вмикаються лише аргументами запуску, звичайна робота їх не торкається).
///   --debug            друкувати події (відкриття, закриття, буфер) у термінал
///   --snapshot <папка> зробити PNG-знімки панелі на всіх вкладках і вийти
enum Debug {
    static let enabled = CommandLine.arguments.contains("--debug")
    /// Для знімків: показати першу картку так, ніби на неї наведено курсор.
    static let forceHover = CommandLine.arguments.contains("--hover")

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[NotchMenu] \(message())\n".utf8))
    }

    static var snapshotDir: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    @MainActor
    static func runSnapshots(panel: PanelController, model: AppModel, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Демо-записи лише в пам'яті цього запуску.
        model.addClip("Зустріч перенесли на 15:30, кабінет 204", source: "Telegram", bundleID: "ru.keepcoder.Telegram")
        model.addClip("func hello() {\n    print(\"Привіт\")\n}", source: "Visual Studio Code", bundleID: "com.microsoft.VSCode")
        model.addClip("name@example.com", source: "Пошта", bundleID: "com.apple.mail")
        model.addClip("+380 67 123 45 67", source: "Telegram", bundleID: "ru.keepcoder.Telegram")
        model.addClip("https://www.apple.com/macbook-pro/", source: "Google Chrome", bundleID: "com.google.Chrome")
        model.addClip("Привіт! Надішли, будь ласка, рахунок до п'ятниці.\nДякую!", source: "Пошта", bundleID: "com.apple.mail")
        model.addToShelf([URL(fileURLWithPath: NSHomeDirectory() + "/Downloads"), URL(fileURLWithPath: "/Applications/Safari.app")])
        model.startTimer(minutes: 25, title: "Pomodoro")
        let steps: [(AppModel.Tab, String)] = [(.home, "1-home"), (.home, "2-answer"), (.clips, "3-clips"), (.downloads, "4-downloads"), (.notes, "4b-notes"), (.system, "5-system"), (.calendar, "6-calendar"), (.settings, "7-settings"), (.visibility, "7b-visibility"), (.shortcuts, "7c-shortcuts")]
        func shoot(_ index: Int) {
            guard index < steps.count else {
                panel.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    write(panel, to: dir.appendingPathComponent("8-closed.png"))
                    NSApp.terminate(nil)
                }
                return
            }
            model.tab = steps[index].0
            if index == 1 {
                model.askedPrompt = "Як коротко ввічливо відмовитись від зустрічі?"
                model.answer = "**Варіант:** «Дякую за запрошення! На жаль, цього разу не зможу долучитися — маю іншу домовленість. Буду радий зустрітися наступного тижня.»\n\nКоротко, тепло й без зайвих пояснень."
                model.showAnswer = true
            } else {
                model.showAnswer = false
            }
            if index == 0 { model.prompt = "120$ + 15%" } else { model.prompt = "" }
            if steps[index].0 == .notes { model.notesMode = 1 }
            if index == 0 { panel.toggleFromHotKey() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                write(panel, to: dir.appendingPathComponent("\(steps[index].1).png"))
                shoot(index + 1)
            }
        }
        shoot(0)
    }

    @MainActor
    private static func write(_ panel: PanelController, to url: URL) {
        guard let view = panel.panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            log("знімок: \(url.lastPathComponent) \(Int(view.bounds.width))×\(Int(view.bounds.height))")
        }
    }
}
