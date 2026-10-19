import AppKit
import ApplicationServices
import Darwin
import NotchCore

/// Читає плеєр YouTube Music у Chrome або Safari через «Універсальний доступ» (той самий дозвіл, що й для лічильників):
/// назву, виконавця, стан і кнопки ⏮ ⏯ ⏭ — без JavaScript і без медіаклавіш.
/// Працює, коли вкладка music.youtube.com активна у своєму вікні браузера.
final class ChromeYouTubeMusic: @unchecked Sendable {
    struct State {
        var title: String?
        var artist: String?
        var isPlaying: Bool?
        var hasButtons = false
        var artworkURL: URL?
    }

    private let lock = NSLock()
    private var playButton: AXUIElement?
    private var nextButton: AXUIElement?
    private var previousButton: AXUIElement?
    private var titleElement: AXUIElement?
    private var bylineElement: AXUIElement?
    private var artworkElement: AXUIElement?
    /// Усі частини рядка під назвою: виконавець, альбом, рік (у порядку на сторінці).
    private var bylineItems: [AXUIElement] = []
    private var enabledFor: pid_t = 0

    static let chromeID = "com.google.Chrome"
    static let safariID = "com.apple.Safari"

    /// Браузер, у якому шукаємо плеєр.
    let browserID: String
    init(browserID: String) { self.browserID = browserID }

    /// `expected` — назва пісні з назви вкладки (вона оновлюється, навіть коли вкладка неактивна).
    func read(expected: String? = nil) -> State? {
        lock.lock(); defer { lock.unlock() }
        guard AXIsProcessTrusted(),
              let browser = NSRunningApplication.runningApplications(withBundleIdentifier: browserID).first,
              let pid = Self.pid(of: browser) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        if enabledFor != pid && browserID != Self.chromeID {
            enabledFor = pid  // Safari показує вміст сторінок і без цього
            playButton = nil
        }
        if enabledFor != pid {
            // Просимо Chrome показати вміст сторінок для «Універсального доступу».
            let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var enhanced = AXError.success
            if manual != .success {
                enhanced = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
            Debug.log("YT Music: увімкнення доступу до сторінок Chrome — manual \(manual.rawValue), enhanced \(enhanced.rawValue)")
            enabledFor = pid
            playButton = nil
        }
        if !isAlive(playButton) || !isAlive(titleElement) { locate(in: app) }

        // Назва й «грає» — із заголовка вікна Chrome (надійно, навіть без елементів сторінки).
        var state = State()
        let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for w in windows {
            if let title = string(w, kAXTitleAttribute), let parsed = YouTubeMusicTitle.parseWindow(title) {
                state.title = parsed.title
                state.artist = parsed.artist
                // Лише Chrome пише в заголовку «відтворюється аудіо»; у Safari стан беремо з кнопки ⏯.
                state.isPlaying = browserID == Self.chromeID ? parsed.playing : nil
                break
            }
        }
        // Еталон — заголовок вікна, а якщо вкладка неактивна — назва вкладки.
        if state.title == nil { state.title = expected }
        guard state.title != nil || playButton != nil || titleElement != nil else { return nil }

        // Назва з рядка плеєра — лише якщо збігається з еталоном. Неактивна вкладка «застигає»:
        // тоді перечитуємо плеєр, а якщо й це не допомогло — беремо назву вкладки.
        var barTitle = titleElement.flatMap(text(of:))
        let windowTitle = state.title
        if let w = windowTitle, let b = barTitle, !Self.sameTrack(b, w) {
            Debug.log("YT Music: у плеєрі «\(b)», а у вкладці «\(w)» — перечитую")
            locate(in: app)
            barTitle = titleElement.flatMap(text(of:))
        }
        let consistent = windowTitle == nil || barTitle == nil || Self.sameTrack(barTitle!, windowTitle!)
        if let t = barTitle, !t.isEmpty, consistent { state.title = t }
        if !consistent { state.artist = nil }
        state.hasButtons = playButton != nil
        if consistent {
            state.artworkURL = artworkElement.flatMap(imageURL).map(Self.biggerArtwork)
                ?? titleElement.flatMap(videoID(in:)).flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/hqdefault.jpg") }
        }
        // Виконавець — перша частина рядка, яка не є роком чи числом.
        let parts = bylineItems.compactMap(text(of:)).flatMap { $0.components(separatedBy: "•") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if consistent, let artist = parts.first(where: { $0.range(of: #"^\d+$"#, options: .regularExpression) == nil }) {
            state.artist = artist
        } else if consistent, let byline = bylineElement.flatMap(text(of:)), byline.range(of: #"[^\d\s•]"#, options: .regularExpression) != nil {
            state.artist = byline.components(separatedBy: "•").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
        }
        if let play = playButton {
            let label = [string(play, kAXDescriptionAttribute), string(play, kAXTitleAttribute), string(play, "AXHelp")]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            if ["pause", "пауза", "призупин", "приостанов", "pausieren"].contains(where: label.contains) { state.isPlaying = true }
            else if ["play", "відтвор", "воспроизв", "wiedergeben"].contains(where: label.contains) { state.isPlaying = false }
        }
        Debug.log("YT Music через AX: «\(state.title ?? "nil")» · «\(state.artist ?? "nil")» · грає: \(state.isPlaying.map { "\($0)" } ?? "?") · кнопки: \(playButton != nil ? "є" : "немає") · обкладинка: \(state.artworkURL?.host ?? "немає")")
        return state
    }

    /// macOS 27 інколи віддає для Safari номер процесу −1 — тоді шукаємо процес за шляхом до програми.
    static func pid(of app: NSRunningApplication) -> pid_t? {
        if app.processIdentifier > 0 { return app.processIdentifier }
        guard let bundle = app.bundleURL?.resolvingSymlinksInPath().path,
              let exe = app.executableURL?.lastPathComponent ?? app.bundleURL?.deletingPathExtension().lastPathComponent else { return nil }
        let expected = bundle + "/Contents/MacOS/" + exe
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            let path = String(cString: buf)
            if path == expected || path.hasSuffix("/" + (app.bundleURL?.lastPathComponent ?? "-") + "/Contents/MacOS/" + exe) { return pid }
        }
        return nil
    }

    func press(_ which: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let target: AXUIElement?
        switch which {
        case "play": target = playButton
        case "next": target = nextButton
        default: target = previousButton
        }
        guard let target else { return false }
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }

    // MARK: Пошук елементів плеєра

    private func locate(in app: AXUIElement) {
        playButton = nil; nextButton = nil; previousButton = nil; titleElement = nil; bylineElement = nil; artworkElement = nil
        bylineItems = []
        let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for window in windows {
            let webArea = findWebArea(window)
            let url = webArea.flatMap(webAreaURL)
            Debug.log("YT Music: вікно «\(string(window, kAXTitleAttribute) ?? "?")», веб-область: \(webArea != nil ? "є" : "немає"), адреса: \(url.map { String($0.prefix(60)) } ?? "nil")")
            guard let webArea, let url, url.contains("music.youtube.com") else { continue }
            var budget = 8000
            walk(webArea, depth: 0, budget: &budget)
            Debug.log("YT Music: вкладку знайдено, кнопка ⏯ \(playButton != nil ? "є" : "немає"), назва \(titleElement != nil ? "є" : "немає")")
            if playButton != nil || titleElement != nil { return }
        }
        Debug.log("YT Music: активної вкладки music.youtube.com не знайдено (\(windows.count) вікон)")
        if Debug.enabled, windows.isEmpty {
            var v: CFTypeRef?
            let w = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v)
            let f = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &v)
            let m = AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &v)
            let kids = children(app).map { string($0, kAXRoleAttribute) ?? "?" }
            Debug.log("YT Music (\(browserID)): windows=\(w.rawValue) focused=\(f.rawValue) main=\(m.rawValue) діти=\(kids)")
        }
    }

    private func findWebArea(_ root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var seen = 0
        while !queue.isEmpty, seen < 3000 {
            let el = queue.removeFirst()
            seen += 1
            if string(el, kAXRoleAttribute) == "AXWebArea" { return el }
            queue.append(contentsOf: children(el))
        }
        return nil
    }

    private func webAreaURL(_ el: AXUIElement) -> String? {
        if let url = attribute(el, kAXURLAttribute) as? URL { return url.absoluteString }
        if let url = attribute(el, kAXURLAttribute) as? NSURL { return url.absoluteString }
        return attribute(el, kAXURLAttribute) as? String
    }

    // Підписи кнопок плеєра різними мовами інтерфейсу YouTube Music.
    private static let playLabels: Set<String> = ["призупинити", "пауза", "pause", "відтворити", "play",
                                                   "приостановить", "воспроизвести", "pausieren", "wiedergeben"]
    private static let nextLabels: Set<String> = ["далі", "наступна", "next", "следующий", "далее", "weiter"]
    private static let previousLabels: Set<String> = ["назад", "попередня", "previous", "предыдущий", "zurück"]

    /// Обходимо сторінку з кінця: першими трапляються кнопки рядка плеєра,
    /// а одразу за ними — посилання з назвою пісні й виконавцем.
    private func walk(_ el: AXUIElement, depth: Int, budget: inout Int) {
        guard budget > 0, depth < 80 else { return }
        budget -= 1
        let role = string(el, kAXRoleAttribute)
        if role == "AXButton" || (role == "AXImage" && playButton != nil && artworkElement == nil) {
            let label = (string(el, kAXDescriptionAttribute) ?? string(el, kAXTitleAttribute) ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            if playButton == nil, Self.playLabels.contains(label) {
                playButton = el
                findNeighbours(of: el)  // «Далі»/«Назад» шукаємо лише поруч із ⏯, не в каруселях сторінки
                findPlayerBarInfo(around: el)  // назва, виконавець, обкладинка — лише з рядка плеєра
                return
            }
        }
        if playButton != nil { return }
        // Рядок плеєра — у самому кінці сторінки, тож обходимо з кінця.
        for child in children(el).reversed() { walk(child, depth: depth + 1, budget: &budget) }
    }

    /// Кнопки «Далі»/«Назад» серед сусідів кнопки ⏯ (підіймаємось до 3 рівнів угору).
    private func findNeighbours(of play: AXUIElement) {
        var container: AXUIElement? = play
        for _ in 0..<3 {
            guard let c = container, let parent = attribute(c, kAXParentAttribute),
                  CFGetTypeID(parent as CFTypeRef) == AXUIElementGetTypeID() else { break }
            let p = parent as! AXUIElement  // тип перевірено рядком вище
            var queue = children(p)
            var seen = 0
            while !queue.isEmpty, seen < 60 {
                let el = queue.removeFirst()
                seen += 1
                if string(el, kAXRoleAttribute) == "AXButton" {
                    let label = (string(el, kAXDescriptionAttribute) ?? string(el, kAXTitleAttribute) ?? "")
                        .trimmingCharacters(in: .whitespaces).lowercased()
                    if nextButton == nil, Self.nextLabels.contains(label) { nextButton = el }
                    if previousButton == nil, Self.previousLabels.contains(label) { previousButton = el }
                }
                queue.append(contentsOf: children(el))
            }
            if nextButton != nil && previousButton != nil { return }
            container = p
        }
    }

    /// Строгіше порівняння (для каталогу): «Love» і «Love Story» — різні пісні, а «Falling (Remastered)» і «Falling» — та сама.
    static func sameSong(_ a: String, _ b: String) -> Bool {
        func base(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: #"\s*[\(\[].*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return base(a) == base(b)
    }

    /// «Falling (feat. X)» і «Falling» — той самий трек.
    static func sameTrack(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        return x == y || x.hasPrefix(y) || y.hasPrefix(x)
    }

    /// Підіймаємось від кнопки ⏯ до рядка плеєра й беремо там посилання (назва, виконавець) і картинку.
    private func findPlayerBarInfo(around play: AXUIElement) {
        var container: AXUIElement? = play
        for level in 0..<7 {
            guard let c = container, let parent = attribute(c, kAXParentAttribute),
                  CFGetTypeID(parent as CFTypeRef) == AXUIElementGetTypeID() else { break }
            let p = parent as! AXUIElement  // тип перевірено рядком вище
            var links: [AXUIElement] = []
            var images: [AXUIElement] = []
            var thumbWrapper: AXUIElement?
            var queue = children(p)
            var seen = 0
            while !queue.isEmpty, seen < 600 {
                let el = queue.removeFirst()
                seen += 1
                let role = string(el, kAXRoleAttribute)
                let classes = (attribute(el, "AXDOMClassList") as? [String]) ?? []
                // Новий міні-плеєр YouTube Music має явні блоки: назва, виконавець, обкладинка.
                if titleElement == nil, classes.contains("ytmusicTrackInfoTitle") { titleElement = el }
                if classes.contains("ytmusicTrackInfoBylineItem") {
                    if bylineElement == nil { bylineElement = el }
                    bylineItems.append(el)
                }
                if thumbWrapper == nil, classes.contains("ytmusicTrackInfoThumbnailWrapper") { thumbWrapper = el }
                // Старий рядок плеєра (так його показує Safari): назва — звичайний текст, під нею «виконавець • альбом • рік».
                if classes.contains("ytmusic-player-bar") {
                    if titleElement == nil, classes.contains("title") { titleElement = el }
                    if bylineElement == nil, classes.contains("byline") { bylineElement = el }
                }
                if classes.contains("ytAttributedStringLink") || role == "AXLink" { links.append(el) }
                if role == "AXImage" { images.append(el) }
                queue.append(contentsOf: children(el))
            }
            if let wrapper = thumbWrapper, artworkElement == nil {
                // У блоці обкладинки шукаємо елемент з адресою картинки.
                var q = [wrapper]; var n = 0
                while !q.isEmpty, n < 40 {
                    let el = q.removeFirst(); n += 1
                    if let u = imageURL(el), Self.isArtworkURL(u) { artworkElement = el; break }
                    if Debug.enabled {
                        var names: CFArray?
                        AXUIElementCopyAttributeNames(el, &names)
                        Debug.log("YT обкладинка-блок (рівень \(level)): \(string(el, kAXRoleAttribute) ?? "?") url=\(imageURL(el)?.absoluteString.prefix(60) ?? "nil") атрибути=\(((names as? [String]) ?? []).joined(separator: ",").prefix(250))")
                    }
                    q.append(contentsOf: children(el))
                }
            }
            // Посилання на канал — це виконавець, а не назва пісні.
            let artistLink = links.first {
                let path = self.imageURL($0)?.path ?? ""
                return path.hasPrefix("/channel/") || path.hasPrefix("/browse/UC")  // сторінка виконавця
            }
            if bylineElement == nil, let artistLink { bylineElement = artistLink }
            if titleElement == nil, artistLink == nil, links.count >= 2 { titleElement = links[0]; bylineElement = links[1] }
            if artworkElement == nil { artworkElement = images.first { imageURL($0).map(Self.isArtworkURL) ?? false } }
            if titleElement != nil && artworkElement != nil { return }
            container = p
        }
    }

    // MARK: Обкладинка

    /// Шукаємо посилання «watch?v=…» у блоці назви треку → ідентифікатор відео.
    private func videoID(in root: AXUIElement) -> String? {
        var q = [root]; var n = 0
        while !q.isEmpty, n < 30 {
            let el = q.removeFirst(); n += 1
            if let u = imageURL(el) {
                Debug.log("YT посилання в назві: \(u.absoluteString.prefix(90))")
                if let id = Self.videoID(from: u) { return id }
            }
            q.append(contentsOf: children(el))
        }
        return nil
    }

    static func videoID(from u: URL) -> String? {
        guard let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems,
              let v = items.first(where: { $0.name == "v" })?.value,
              v.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
        return v
    }

    private func imageURL(_ el: AXUIElement) -> URL? {
        if let u = attribute(el, kAXURLAttribute) as? URL { return u }
        if let u = attribute(el, kAXURLAttribute) as? NSURL { return u as URL }
        if let s = attribute(el, kAXURLAttribute) as? String { return URL(string: s) }
        return nil
    }

    static func isArtworkURL(_ u: URL) -> Bool {
        let host = u.host ?? ""
        return host.hasSuffix("googleusercontent.com") || host.hasSuffix("ytimg.com") || host.hasSuffix("ggpht.com")
    }

    /// Мініатюра в рядку плеєра маленька (60×60) — просимо в Google більшу (300×300).
    static func biggerArtwork(_ u: URL) -> URL {
        let s = u.absoluteString
        if let r = s.range(of: #"=w\d+-h\d+"#, options: .regularExpression) {
            return URL(string: s.replacingCharacters(in: r, with: "=w300-h300")) ?? u
        }
        return u
    }

    // MARK: Дрібні помічники

    private func text(of el: AXUIElement) -> String? {
        for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = string(el, key), !s.isEmpty { return s }
        }
        // Текст часто лежить глибше — у дочірніх «статичних текстах» (до 4 рівнів).
        var parts: [String] = []
        var q: [(AXUIElement, Int)] = children(el).map { ($0, 1) }
        while !q.isEmpty, parts.count < 6 {
            let (e, depth) = q.removeFirst()
            let role = string(e, kAXRoleAttribute)
            if role == "AXStaticText", let v = string(e, kAXValueAttribute), !v.isEmpty { parts.append(v); continue }
            // Chrome показує виконавця й альбом як кнопки з підписом (без тексту всередині).
            if role == "AXButton" || role == "AXLink", let t = string(e, kAXTitleAttribute), !t.isEmpty, children(e).isEmpty {
                parts.append(t); continue
            }
            if depth < 4 { q.append(contentsOf: children(e).map { ($0, depth + 1) }) }
        }
        let joined = parts.joined().trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }

    private func isAlive(_ el: AXUIElement?) -> Bool {
        guard let el else { return false }
        return string(el, kAXRoleAttribute) != nil
    }

    private func children(_ el: AXUIElement) -> [AXUIElement] {
        (attribute(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func string(_ el: AXUIElement, _ name: String) -> String? {
        attribute(el, name) as? String
    }

    private func attribute(_ el: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }
}
