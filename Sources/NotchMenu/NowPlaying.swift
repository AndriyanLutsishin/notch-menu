import AppKit
import NotchCore

/// «Зараз грає»: Apple Music або YouTube Music (у Google Chrome) — на вибір.
///  • Apple Music: назву розсилає сама macOS; обкладинка й кнопки — через дозвіл «керувати Музикою».
///  • YouTube Music: назву беремо із заголовка вкладки music.youtube.com (дозвіл «керувати Chrome»),
///    кнопки — як медіаклавіші клавіатури (дозвіл «Універсальний доступ»). Жодного JavaScript у вкладках.
@MainActor
final class NowPlaying: ObservableObject {
    static let musicID = "com.apple.Music"
    static let chromeID = "com.google.Chrome"
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

    // MARK: YouTube Music (у Chrome)

    private let ytm = ChromeYouTubeMusic()
    /// Чи вдалося знайти кнопки плеєра YouTube Music (тоді показуємо ⏮ ⏯ ⏭).
    @Published private(set) var youtubeControls = false
    private var youtubeReadInFlight = false

    private func refreshYouTubeMusic() {
        guard isRunning(Self.chromeID) else { clear(); youtubeControls = false; return }
        guard !youtubeReadInFlight else { return }  // попереднє читання ще не закінчилось
        youtubeReadInFlight = true
        refreshYouTubeVideoID()
        // Спершу — сам плеєр на сторінці через «Універсальний доступ».
        let ytm = self.ytm
        Task.detached(priority: .utility) {
            let state = ytm.read()
            await MainActor.run {
                self.youtubeReadInFlight = false
                guard self.source == .youtubeMusic else { return }
                if var state, state.title != nil || state.isPlaying != nil {
                    if state.artworkURL == nil, let id = self.youtubeVideoID {
                        state.artworkURL = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
                    }
                    if state.artworkURL == nil, let t = state.title {
                        // Chrome не віддає обкладинку міні-плеєра — шукаємо її в каталозі Apple Music за назвою.
                        self.lookUpArtwork(title: t, artist: state.artist)
                        state.artworkURL = self.catalogArtworkURL
                    }
                    self.youtubeControls = state.hasButtons
                    self.title = state.title
                    self.artist = state.artist
                    self.album = nil
                    self.isPlaying = state.isPlaying
                    self.loadYouTubeArtwork(state.artworkURL)
                } else {
                    self.youtubeControls = false
                    self.refreshYouTubeMusicByTitle()
                }
            }
        }
    }

    private var youtubeArtworkURL: URL?
    private var catalogKey: String?
    private var catalogArtworkURL: URL?

    /// Відкритий каталог iTunes/Apple Music: надсилаємо лише назву треку й виконавця, без жодних інших даних.
    private func lookUpArtwork(title: String, artist: String?) {
        let key = "\(title)|\(artist ?? "")"
        guard key != catalogKey else { return }
        catalogKey = key
        catalogArtworkURL = nil
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
            if self.source == .youtubeMusic { self.loadYouTubeArtwork(big) }
        }
    }
    /// Ідентифікатор треку з адреси вкладки (music.youtube.com/watch?v=…), якщо відкрито повний плеєр.
    private var youtubeVideoID: String?

    private func refreshYouTubeVideoID() {
        run("""
            if application "Google Chrome" is running then
              tell application "Google Chrome"
                repeat with w in windows
                  repeat with t in tabs of w
                    if URL of t contains "music.youtube.com" then return URL of t
                  end repeat
                end repeat
              end tell
            end if
            return ""
            """, app: "Google Chrome") { [weak self] result in
            guard let self, let s = result?.stringValue, let u = URL(string: s) else { return }
            self.youtubeVideoID = ChromeYouTubeMusic.videoID(from: u)
        }
    }
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

    /// Запасний спосіб: заголовок вкладки (у YouTube Music там часто лише «YouTube Music»).
    private func refreshYouTubeMusicByTitle() {
        run("""
            if application "Google Chrome" is running then
              tell application "Google Chrome"
                repeat with w in windows
                  repeat with t in tabs of w
                    if URL of t contains "music.youtube.com" then return title of t
                  end repeat
                end repeat
              end tell
            end if
            return ""
            """, app: "Google Chrome") { [weak self] result in
            guard let self, self.source == .youtubeMusic else { return }
            Debug.log("YouTube Music, заголовок вкладки: «\(result?.stringValue ?? "nil")»")
            guard let raw = result?.stringValue, let parsed = YouTubeMusicTitle.parse(raw) else {
                if result != nil { self.clear() }
                return
            }
            self.title = parsed.title
            self.artist = parsed.artist
            self.album = nil
            self.loadYouTubeArtwork(nil)  // скидаємо й адресу, щоб обкладинка повернулась при наступному читанні
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

    /// Перемикає Chrome на вкладку YouTube Music (або відкриває її, якщо такої немає).
    func showYouTubeMusicTab() {
        guard isRunning(Self.chromeID) else { NSWorkspace.shared.open(Self.youtubeMusicURL); return }
        run("""
            tell application "Google Chrome"
              repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                  set i to i + 1
                  if URL of t contains "music.youtube.com" then
                    set active tab index of w to i
                    set index of w to 1
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            return ""
            """, app: "Google Chrome") { result in
            if result?.stringValue != "ok" { NSWorkspace.shared.open(Self.youtubeMusicURL) }
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
        let id = source == .appleMusic ? Self.musicID : Self.chromeID
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
