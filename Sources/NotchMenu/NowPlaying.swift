import AppKit
import NotchCore

/// «Зараз грає»: Apple Music або YouTube Music (у Google Chrome чи Safari) — на вибір.
///  • Apple Music: назву розсилає сама macOS; обкладинка й кнопки — через дозвіл «керувати Музикою».
///  • YouTube Music: назву беремо із заголовка вкладки music.youtube.com (дозвіл «керувати Chrome»),
///    кнопки — як медіаклавіші клавіатури (дозвіл «Універсальний доступ»). Жодного JavaScript у вкладках.
@MainActor
final class NowPlaying: ObservableObject {
    static let musicID = "com.apple.Music"
    static let chromeID = "com.google.Chrome"
    static let safariID = "com.apple.Safari"
    static let youtubeMusicURL = URL(string: "https://music.youtube.com/")!

    @Published var source: MusicSource {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: "musicSource")
            clear()
            refresh()
        }
    }
    @Published private(set) var title: String?
    @Published private(set) var artist: String?
    @Published private(set) var album: String?
    /// nil — невідомо (YouTube Music не повідомляє, грає чи пауза).
    @Published private(set) var isPlaying: Bool?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var needsPermission: String?

    private var artworkKey: String?
    private var pollTimer: Timer?
    private let queue = DispatchQueue(label: "notchmenu.applescript")

    var hasTrack: Bool { title != nil }

    init() {
        source = MusicSource(rawValue: UserDefaults.standard.string(forKey: "musicSource") ?? "") ?? .appleMusic
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.applyMusic(info) }
        }
    }

    private func isRunning(_ id: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    private func clear() {
        title = nil; artist = nil; album = nil; isPlaying = nil; artwork = nil; artworkKey = nil; youtubeArtworkURL = nil
    }

    // MARK: Панель відкрилась / закрилась

    func panelDidOpen() {
        refresh()
        pollTimer?.invalidate()
        // YouTube Music сам нічого не повідомляє — поки панель відкрита, перевіряємо раз на 2 с.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.source == .youtubeMusic else { return }
                self.refresh()
            }
        }
    }

    func panelDidClose() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        switch source {
        case .appleMusic: refreshAppleMusic()
        case .youtubeMusic: refreshYouTubeMusic()
        }
    }

    // MARK: Apple Music

    private func applyMusic(_ info: [AnyHashable: Any]) {
        guard source == .appleMusic else { return }
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" { clear(); return }
        isPlaying = state == "Playing"
        if let name = info["Name"] as? String { title = name }
        artist = info["Artist"] as? String
        album = info["Album"] as? String
        loadArtworkIfNeeded()
    }

    private func refreshAppleMusic() {
        guard isRunning(Self.musicID) else { clear(); return }
        run("""
            if application "Music" is running then
              tell application "Music"
                set st to player state as string
                if st is "stopped" then return {"stopped", "", "", ""}
                return {st, name of current track, artist of current track, album of current track}
              end tell
            end if
            return {"stopped", "", "", ""}
            """, app: "«Музикою»") { [weak self] result in
            guard let self, self.source == .appleMusic, let list = result, list.numberOfItems >= 4 else { return }
            let st = list.atIndex(1)?.stringValue ?? "stopped"
            if st == "stopped" { self.clear(); return }
            self.isPlaying = st == "playing"
            self.title = list.atIndex(2)?.stringValue
            self.artist = list.atIndex(3)?.stringValue
            self.album = list.atIndex(4)?.stringValue
            self.loadArtworkIfNeeded()
        }
    }

    private func loadArtworkIfNeeded() {
        let key = "\(title ?? "")|\(album ?? "")"
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil
        run("""
            if application "Music" is running then
              tell application "Music"
                try
                  return data of artwork 1 of current track
                end try
              end tell
            end if
            return ""
            """, app: "«Музикою»") { [weak self] result in
            // Обкладинка має належати саме цьому треку й джерелу (поки чекали, трек міг змінитися).
            guard let self, self.artworkKey == key, self.source == .appleMusic,
                  let data = result?.data, !data.isEmpty, let image = NSImage(data: data) else { return }
            self.artwork = image
        }
    }

    // MARK: YouTube Music (у Chrome або Safari)

    private let readers = [ChromeYouTubeMusic(browserID: chromeID), ChromeYouTubeMusic(browserID: safariID)]
    /// Браузер, де востаннє знайшли YouTube Music (туди й ідуть кнопки).
    @Published private(set) var youtubeBrowser = chromeID
    private var ytm: ChromeYouTubeMusic { readers.first { $0.browserID == youtubeBrowser } ?? readers[0] }

    private var runningBrowsers: [String] {
        let running = [Self.chromeID, Self.safariID].filter(isRunning)
        // Спершу той, де YouTube Music був минулого разу.
        return running.sorted { a, _ in a == youtubeBrowser }
    }

    private static func appName(_ browser: String) -> String { browser == safariID ? "Safari" : "Google Chrome" }
    /// Назва вкладки в AppleScript: у Chrome — title, у Safari — name.
    private static func tabTitleKey(_ browser: String) -> String { browser == safariID ? "name" : "title" }
    /// Чи вдалося знайти кнопки плеєра YouTube Music (тоді показуємо ⏮ ⏯ ⏭).
    @Published private(set) var youtubeControls = false
    private var youtubeReadInFlight = false

    private func refreshYouTubeMusic() {
        let browsers = runningBrowsers
        guard !browsers.isEmpty else { clear(); youtubeControls = false; return }
        guard !youtubeReadInFlight else { return }  // попереднє читання ще не закінчилось
        youtubeReadInFlight = true
        // 1) Назва вкладки — вона оновлюється завжди, навіть коли вкладка неактивна.
        findYouTubeTab(in: browsers) { [weak self] tab in
            guard let self else { return }
            guard self.source == .youtubeMusic else { self.youtubeReadInFlight = false; return }
            let tabTitle = tab.flatMap { YouTubeMusicTitle.parse($0.title)?.title }
            if let tab {
                if self.youtubeBrowser != tab.browser { self.youtubeBrowser = tab.browser }
                self.youtubeVideoID = URL(string: tab.url).flatMap(ChromeYouTubeMusic.videoID(from:))
            }
            // 2) Сам плеєр на сторінці через «Універсальний доступ» — виконавець, стан, кнопки.
            let order = tab.map { t in [t.browser] + browsers.filter { $0 != t.browser } } ?? browsers
            let readers = order.compactMap { b in self.readers.first { $0.browserID == b } }
            let tabBrowser = tab?.browser
            Task.detached(priority: .utility) {
                let found: (browser: String, state: ChromeYouTubeMusic.State)? = {
                    for r in readers {
                        let expected = r.browserID == tabBrowser ? tabTitle : nil
                        if let st = r.read(expected: expected), st.title != nil || st.isPlaying != nil { return (r.browserID, st) }
                    }
                    return nil
                }()
                await MainActor.run {
                    self.youtubeReadInFlight = false
                    guard self.source == .youtubeMusic else { return }
                    if let found {
                        self.youtubeBrowser = found.browser
                        self.apply(found.state)
                    } else if let tabTitle, let tab {
                        // «Універсального доступу» немає — лише назва вкладки.
                        var state = ChromeYouTubeMusic.State()
                        state.title = tabTitle
                        state.artist = YouTubeMusicTitle.parse(tab.title)?.artist
                        self.apply(state)
                    } else {
                        self.youtubeControls = false
                        if tab == nil { self.clear() }
                    }
                }
            }
        }
    }

    /// Виконавці, яких ми вже бачили в плеєрі (назва пісні → виконавець).
    private var knownArtists: [String: String] = [:]

    private func apply(_ found: ChromeYouTubeMusic.State) {
        var state = found
        if let t = state.title, let a = state.artist, !a.isEmpty { knownArtists[t] = a }
        if state.artist == nil, let t = state.title {
            state.artist = knownArtists[t] ?? (catalogTitle.map { ChromeYouTubeMusic.sameSong($0, t) } == true ? catalogArtist : nil)
        }
        if state.artworkURL == nil, let id = youtubeVideoID {
            state.artworkURL = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        }
        if state.artworkURL == nil, let t = state.title {
            // Браузер не завжди віддає обкладинку — шукаємо її (і виконавця) в каталозі Apple Music за назвою.
            lookUpArtwork(title: t, artist: state.artist)
            state.artworkURL = catalogArtworkURL
        }
        youtubeControls = state.hasButtons
        title = state.title
        artist = state.artist
        album = nil
        isPlaying = state.isPlaying
        loadYouTubeArtwork(state.artworkURL)
    }

    /// Вкладка music.youtube.com: (браузер, назва, адреса). Шукаємо по черзі в кожному браузері.
    private func findYouTubeTab(in browsers: [String], completion: @escaping @MainActor ((browser: String, title: String, url: String)?) -> Void) {
        guard let browser = browsers.first else { completion(nil); return }
        let name = Self.appName(browser)
        run("""
            if application "\(name)" is running then
              tell application "\(name)"
                repeat with w in windows
                  repeat with t in tabs of w
                    if URL of t contains "music.youtube.com" then return (\(Self.tabTitleKey(browser)) of t) & linefeed & (URL of t)
                  end repeat
                end repeat
              end tell
            end if
            return ""
            """, app: name) { [weak self] result in
            let parts = (result?.stringValue ?? "").components(separatedBy: "\n")
            if parts.count >= 2 {
                Debug.log("YouTube Music (\(name)), вкладка: «\(parts[0])»")
                completion((browser, parts[0], parts[1]))
            } else if browsers.count > 1 {
                self?.findYouTubeTab(in: Array(browsers.dropFirst()), completion: completion)
            } else {
                completion(nil)
            }
        }
    }

    private var youtubeArtworkURL: URL?
    private var catalogKey: String?
    private var catalogArtworkURL: URL?
    private var catalogTitle: String?
    private var catalogArtist: String?

    /// Відкритий каталог iTunes/Apple Music: надсилаємо лише назву треку й виконавця, без жодних інших даних.
    private func lookUpArtwork(title: String, artist: String?) {
        let key = "\(title)|\(artist ?? "")"
        guard key != catalogKey else { return }
        catalogKey = key
        catalogArtworkURL = nil
        catalogTitle = nil
        catalogArtist = nil
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [URLQueryItem(name: "term", value: [title, artist].compactMap { $0 }.joined(separator: " ")),
                        URLQueryItem(name: "entity", value: "song"), URLQueryItem(name: "limit", value: "1")]
        guard let url = c.url else { return }
        Debug.log("YT обкладинка: шукаю в каталозі Apple Music…")
        Task {
            let result = try? await imageSession.data(from: url)
            guard let (data, _) = result else { Debug.log("YT каталог: немає відповіді"); return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (json["results"] as? [[String: Any]])?.first,
                  let art = first["artworkUrl100"] as? String else { Debug.log("YT каталог: трек не знайдено"); return }
            guard self.catalogKey == key else { return }
            let big = URL(string: art.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
            Debug.log("YT обкладинка з каталогу Apple Music: \(big?.host ?? "nil")")
            self.catalogArtworkURL = big
            self.catalogTitle = first["trackName"] as? String
            self.catalogArtist = first["artistName"] as? String
            // Виконавця з каталогу показуємо, лише якщо назва пісні там та сама.
            if self.source == .youtubeMusic, self.artist == nil, let t = self.title, let ct = self.catalogTitle,
               ChromeYouTubeMusic.sameSong(ct, t), let a = self.catalogArtist {
                self.artist = a
            }
            if self.source == .youtubeMusic { self.loadYouTubeArtwork(big) }
        }
    }
    /// Ідентифікатор треку з адреси вкладки (music.youtube.com/watch?v=…), якщо відкрито повний плеєр.
    private var youtubeVideoID: String?

    private let imageSession = URLSession(configuration: .ephemeral)

    /// Обкладинка YouTube Music — картинка з серверів Google (тих самих, звідки грає музика).
    private func loadYouTubeArtwork(_ url: URL?) {
        guard url != youtubeArtworkURL else { return }
        youtubeArtworkURL = url
        artwork = nil
        guard let url else { return }
        Task {
            guard let (data, _) = try? await imageSession.data(from: url),
                  let image = NSImage(data: data), self.youtubeArtworkURL == url, self.source == .youtubeMusic else {
                Debug.log("YT обкладинка: не вдалося завантажити \(url.absoluteString.prefix(60))")
                return
            }
            Debug.log("YT обкладинка: є (\(url.host ?? ""))")
            self.artwork = image
        }
    }

    // MARK: Кнопки

    // Для YouTube Music керувати відтворенням напряму не можна без небезпечного дозволу
    // «JavaScript з Apple Events» у Chrome, а медіаклавіші йдуть у будь-який плеєр (напр. Netflix).
    // Тому кнопки є лише для Apple Music, а для YouTube Music — «Перейти до вкладки».
    func playPause() { source == .youtubeMusic ? youtube("play") : musicCommand("playpause") }
    func next() { source == .youtubeMusic ? youtube("next") : musicCommand("next track") }
    func previous() { source == .youtubeMusic ? youtube("previous") : musicCommand("previous track") }

    /// Натискає саму кнопку на сторінці YouTube Music (не медіаклавішу — тож Netflix не зачепить).
    private func youtube(_ which: String) {
        let ytm = self.ytm
        Task.detached(priority: .userInitiated) {
            let ok = ytm.press(which)
            await MainActor.run {
                if !ok { self.showYouTubeMusicTab() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
            }
        }
    }

    private func musicCommand(_ command: String) {
        guard source == .appleMusic else { return }
        guard isRunning(Self.musicID) else { openSource(); return }
        run("tell application \"Music\" to \(command)", app: "«Музикою»") { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.refresh() }
        }
    }

    // MARK: Пауза під час дзвінка

    /// Ставить на паузу, лише якщо зараз грає. У completion — чи справді поставили.
    func pauseIfPlaying(completion: @escaping @MainActor (Bool) -> Void) {
        switch source {
        case .appleMusic:
            guard isRunning(Self.musicID) else { completion(false); return }
            run("""
                tell application "Music"
                  if player state is playing then
                    pause
                    return "paused"
                  end if
                end tell
                return ""
                """, app: "«Музикою»") { result in completion(result?.stringValue == "paused") }
        case .youtubeMusic:
            let ytm = self.ytm
            Task.detached(priority: .userInitiated) {
                let playing = ytm.read()?.isPlaying == true
                let ok = playing && ytm.press("play")
                await MainActor.run { completion(ok) }
            }
        }
    }

    func resumePlaying() {
        switch source {
        case .appleMusic:
            guard isRunning(Self.musicID) else { return }
            run("tell application \"Music\" to play", app: "«Музикою»") { _ in }
        case .youtubeMusic:
            let ytm = self.ytm
            Task.detached(priority: .userInitiated) {
                if ytm.read()?.isPlaying == false { _ = ytm.press("play") }
            }
        }
    }

    /// Перемикає браузер на вкладку YouTube Music (або відкриває її, якщо такої немає).
    func showYouTubeMusicTab() {
        showYouTubeMusicTab(in: runningBrowsers)
    }

    private func showYouTubeMusicTab(in browsers: [String]) {
        guard let browser = browsers.first else { NSWorkspace.shared.open(Self.youtubeMusicURL); return }
        let name = Self.appName(browser)
        let select = browser == Self.safariID ? "set current tab of w to t" : "set active tab index of w to i"
        run("""
            tell application "\(name)"
              repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                  set i to i + 1
                  if URL of t contains "music.youtube.com" then
                    \(select)
                    set index of w to 1
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            return ""
            """, app: name) { [weak self] result in
            guard result?.stringValue != "ok" else { return }
            if browsers.count > 1 { self?.showYouTubeMusicTab(in: Array(browsers.dropFirst())) }
            else { NSWorkspace.shared.open(Self.youtubeMusicURL) }
        }
    }

    func openSource() {
        switch source {
        case .appleMusic:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.musicID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .youtubeMusic:
            showYouTubeMusicTab()
        }
    }

    var sourceIcon: NSImage? {
        let id = source == .appleMusic ? Self.musicID : youtubeBrowser
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    /// Виконує AppleScript у фоні; результат — на головному потоці.
    private func run(_ source: String, app: String, completion: @escaping @MainActor (NSAppleEventDescriptor?) -> Void) {
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let code = error?[NSAppleScript.errorNumber] as? Int
            Debug.log("AppleScript (\(app)): \(code.map { "помилка \($0) \(error?[NSAppleScript.errorMessage] ?? "")" } ?? "ок")")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if code == -1743 { self.needsPermission = app }  // не дозволено керувати програмою
                    else if code == nil, self.needsPermission == app { self.needsPermission = nil }
                    completion(code == nil ? result : nil)
                }
            }
        }
    }
}
