import AppKit
import Combine
import SwiftUI

/// Де на екрані чубчик (або, якщо його немає, — середина рядка меню).
struct NotchGeometry {
    let screen: NSScreen

    var hasNotch: Bool {
        screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
    }

    var menuBarHeight: CGFloat {
        let h = screen.frame.maxY - screen.visibleFrame.maxY
        return h > 0 ? h : 24
    }

    /// Прямокутник чубчика в глобальних координатах.
    var notchRect: NSRect {
        let f = screen.frame
        if hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let h = screen.safeAreaInsets.top
            let minX = f.minX + left.width
            let maxX = f.maxX - right.width
            return NSRect(x: minX, y: f.maxY - h, width: maxX - minX, height: h)
        }
        let w: CGFloat = 180
        return NSRect(x: f.midX - w / 2, y: f.maxY - menuBarHeight, width: w, height: menuBarHeight)
    }

    /// Куди наводити курсор, щоб відкрити панель.
    var hotZone: NSRect {
        let f = screen.frame
        if hasNotch { return notchRect.insetBy(dx: 0, dy: -1) }
        // Без чубчика — тонка смужка біля самого верху посередині (щоб не заважати меню).
        return NSRect(x: f.midX - 110, y: f.maxY - 3, width: 220, height: 4)
    }

    static func screenWithNotch() -> NSScreen? {
        NSScreen.screens.first { NotchGeometry(screen: $0).hasNotch }
    }
}

final class PanelState: ObservableObject {
    @Published var expanded = false
    @Published var notchSize = CGSize(width: 200, height: 32)
    @Published var hasNotch = true
    @Published var focusToken = 0
    /// Ширина розкритої панелі; висоту задає модель (компактна головна, довші вкладки).
    let expandedWidth: CGFloat = 840
    /// Загин біля рамки екрана: малий у згорнутому стані, «вушка» — у розкритому.
    let collapsedTopRadius: CGFloat = 8
    let expandedTopRadius: CGFloat = 14
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Панель без рамки, яка може приймати текст, але не «перемикає» активну програму.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)  // над рядком меню
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Вікно панелі завжди найбільшого розміру (щоб не смикалось), тож клік у прозору
/// частину під чорною фігурою вважаємо «кліком деінде» — панель закривається.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    var isInsideVisibleShape: (NSPoint) -> Bool = { _ in true }
    var onClickOutside: () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        let screenPoint = window.convertPoint(toScreen: convert(local, to: nil))
        if isInsideVisibleShape(screenPoint) { return super.hitTest(point) }
        if let type = NSApp.currentEvent?.type, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
            DispatchQueue.main.async { self.onClickOutside() }
        }
        return nil
    }
}

@MainActor
final class PanelController: NSObject {
    let panel = NotchPanel()
    let state = PanelState()
    let model: AppModel
    private(set) var isOpen = false
    private(set) var openedByHover = false
    private(set) var screen: NSScreen?
    private var keyMonitor: Any?
    /// Висота вікна зараз (вікно росте одразу, а зменшується після анімації).
    private var windowHeight: CGFloat = 0

    /// Поля навколо фігури, щоб тінь не обрізалась.
    private let margin: CGFloat = 40

    init(model: AppModel) {
        self.model = model
        super.init()
        let root = PanelRootView(model: model, state: state)
        let hosting = PanelHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.isInsideVisibleShape = { [weak self] screenPoint in
            self?.visibleRect.contains(screenPoint) ?? false
        }
        hosting.onClickOutside = { [weak self] in self?.close() }
        panel.contentView = hosting

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        // Esc закриває панель.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, event.keyCode == 53, self.model.recordingShortcut == nil else { return event }
            self.close()
            return nil
        }
    }

    private func frame(height: CGFloat, on target: NSScreen) -> NSRect {
        let notch = NotchGeometry(screen: target).notchRect
        let w = state.expandedWidth + margin * 2
        let h = height + margin
        var x = notch.midX - w / 2
        x = min(max(x, target.frame.minX), target.frame.maxX - w)
        return NSRect(x: x, y: target.frame.maxY - h, width: w, height: h)
    }

    /// Видима частина панелі (без полів для тіні) у глобальних координатах.
    var visibleRect: NSRect {
        let f = panel.frame
        let w = state.expandedWidth, h = model.panelHeight
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    func toggleFromHotKey() {
        if isOpen && !openedByHover { close(); return }
        let mouse = NSEvent.mouseLocation
        let target = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NotchGeometry.screenWithNotch() ?? NSScreen.main
        guard let target else { return }
        open(on: target, byHover: false)
    }

    func open(on target: NSScreen, byHover: Bool) {
        let geo = NotchGeometry(screen: target)
        let notch = geo.notchRect
        // Вікно завжди найбільшого розміру: так панель не «смикається» при перемиканні вкладок.
        windowHeight = AppModel.maxPanelHeight
        panel.setFrame(frame(height: windowHeight, on: target), display: false)

        state.notchSize = CGSize(width: notch.width + state.collapsedTopRadius * 2, height: notch.height)
        state.hasNotch = geo.hasNotch
        screen = target
        openedByHover = byHover
        Debug.log("панель відкрито (\(byHover ? "наведенням" : "клавішею")), чубчик: \(geo.hasNotch), \(notch)")

        if !isOpen {
            state.expanded = false
            isOpen = true
            model.panelDidOpen()
        }
        if byHover {
            panel.orderFrontRegardless()
        } else {
            panel.makeKeyAndOrderFront(nil)
            state.focusToken += 1
        }
        DispatchQueue.main.async { [state] in
            withAnimation(state.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.82)) {
                state.expanded = true
            }
        }
    }

    /// Користувач клікнув у панель — вона більше не закривається, коли курсор іде геть.
    func pin() { openedByHover = false }

    /// До цього часу панель не ховається сама (наприклад, коли таймер дзвенить).
    private(set) var holdOpenUntil = Date.distantPast

    /// Показати панель без захоплення клавіатури й потримати кілька секунд.
    func flash(seconds: TimeInterval = 8) {
        guard let target = NotchGeometry.screenWithNotch() ?? NSScreen.main else { return }
        holdOpenUntil = Date().addingTimeInterval(seconds)
        if !isOpen { open(on: target, byHover: true) }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        Debug.log("панель закрито")
        model.panelDidClose()
        withAnimation(.easeIn(duration: state.reduceMotion ? 0.1 : 0.2)) {
            state.expanded = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self, !self.isOpen else { return }
            self.panel.orderOut(nil)
        }
    }
}

/// Стежить за курсором: навів на чубчик — панель виїжджає; відвів — ховається.
/// Лише читає положення курсора, тому жодних дозволів macOS не потрібно.
@MainActor
final class HoverWatcher {
    private let panel: PanelController
    private var timer: Timer?
    private var dwellStart: Date?
    private var outsideSince: Date?
    private var waitForExit = false
    private var lastDragCount = NSPasteboard(name: .drag).changeCount

    init(panel: PanelController) {
        self.panel = panel
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.03
    }

    private func zoneScreen(_ p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NotchGeometry(screen: $0).hotZone.contains(p) }
    }

    private func tick() {
        let p = NSEvent.mouseLocation
        let now = Date()

        if panel.isOpen {
            dwellStart = nil
            guard panel.openedByHover else { outsideSince = nil; return }
            if panel.panel.isKeyWindow { panel.pin(); return }
            if Date() < panel.holdOpenUntil { outsideSince = nil; return }
            let inside = panel.visibleRect.insetBy(dx: -12, dy: -12).contains(p) || zoneScreen(p) != nil
            if inside {
                outsideSince = nil
            } else if let since = outsideSince {
                if now.timeIntervalSince(since) > 0.45 {
                    panel.close()
                    outsideSince = nil
                    waitForExit = zoneScreen(p) != nil
                }
            } else {
                outsideSince = now
            }
            return
        }

        // Перетягують файл? Тоді відкриваємо панель на «Буфері», щоб покласти його на полицю.
        let pressed = NSEvent.pressedMouseButtons != 0
        let dragCount = NSPasteboard(name: .drag).changeCount
        if !pressed { lastDragCount = dragCount }
        let draggingFile = pressed && dragCount != lastDragCount

        let screen = zoneScreen(p)
        if draggingFile, let screen, !panel.isOpen {
            panel.model.tab = .clips
            panel.open(on: screen, byHover: true)
            waitForExit = true
            return
        }
        if waitForExit {
            if screen == nil { waitForExit = false }
            return
        }
        guard let screen, NSEvent.pressedMouseButtons == 0 else { dwellStart = nil; return }
        if let start = dwellStart {
            if now.timeIntervalSince(start) > 0.12 {
                dwellStart = nil
                waitForExit = true
                panel.open(on: screen, byHover: true)
            }
        } else {
            dwellStart = now
        }
    }
}
