import AppKit

// Точка входу. Програма без іконки в Dock (LSUIElement у Info.plist).
// Якщо Claude/Codex завершиться, поки ми ще пишемо йому текст, — не падаємо від SIGPIPE.
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
