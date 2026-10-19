import AppKit
import NotchCore
import SwiftUI

/// Маленька червона «пігулка» праворуч від чубчика — лише коли перегрів або слабка батарея.
/// Клік відкриває панель на екрані «Система».
@MainActor
final class WarningIndicator {
    private let window: NSPanel
    private let hosting: NSHostingView<WarningPill>
    private var current: SystemWarning?
    var onClick: () -> Void = {}

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: WarningPill(text: "", action: {}))
        window.contentView = hosting
    }

    func update(warning: SystemWarning?, panelOpen: Bool) {
        guard let warning, !panelOpen,
              let screen = NotchGeometry.screenWithNotch() ?? NSScreen.main else {
            if window.isVisible { window.orderOut(nil) }
            current = nil
            return
        }
        if warning != current || !window.isVisible {
            current = warning
            hosting.rootView = WarningPill(text: warning.text) { [weak self] in self?.onClick() }
            let notch = NotchGeometry(screen: screen).notchRect
            let size = NSSize(width: 74, height: notch.height)
            window.setFrame(NSRect(x: notch.maxX + 6, y: screen.frame.maxY - size.height, width: size.width, height: size.height),
                            display: true)
            window.orderFrontRegardless()
        }
    }
}

struct WarningPill: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color(red: 0.9, green: 0.2, blue: 0.15)))
        }
        .buttonStyle(.plain)
        .help("Mac просить уваги — клік покаже деталі")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
