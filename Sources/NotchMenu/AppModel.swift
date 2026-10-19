import AppKit
import NotchCore
import ServiceManagement
import SwiftUI

/// Який секрет вводимо: ключ Claude API чи токен монобанку.
enum SecretKind: String, Identifiable {
    case anthropic, monobank, gemini
    var id: String { rawValue }

    var service: String { "com.andriyan.notchmenu.\(rawValue)" }
    var keychainLabel: String {
        switch self {
        case .anthropic: return "Notch Menu — ключ Claude API"
        case .monobank: return "Notch Menu — токен монобанку"
        case .gemini: return "Notch Menu — ключ Gemini"
        }
    }
}

/// Увесь стан програми. Нічого з історії буфера чи монобанку не пишеться на диск.
@MainActor
final class AppModel: ObservableObject {
    enum Tab: String, CaseIterable { case home, clips, downloads, mono, notes, system, calendar, settings, visibility, shortcuts }

    // MARK: Комбінації клавіш (можна змінити в налаштуваннях)
    @Published private(set) var shortcuts: [ShortcutAction: Shortcut] = {
        var map: [ShortcutAction: Shortcut] = [:]
        for a in ShortcutAction.allCases {
            if let data = UserDefaults.standard.data(forKey: a.storageKey),
               let s = try? JSONDecoder().decode(Shortcut.self, from: data) { map[a] = s } else { map[a] = a.defaultShortcut }
        }
        return map
    }()
    @Published private(set) var recordingShortcut: ShortcutAction?
    @Published var shortcutNote: String?
    /// Комбінації, які не вдалося зареєструвати (зайняті іншою програмою).
    @Published var shortcutConflicts: Set<ShortcutAction> = []
    var onShortcutsChanged: (() -> Void)?
    private var recorder: Any?

    func shortcut(_ a: ShortcutAction) -> Shortcut { shortcuts[a] ?? a.defaultShortcut }

    func startRecording(_ a: ShortcutAction) {
        stopRecording()
        recordingShortcut = a
        shortcutNote = "Натисни нову комбінацію для «\(a.title)» (Esc — скасувати)"
        onShortcutsChanged?()  // поки записуємо — старі комбінації вимкнено
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recordingShortcut else { return event }
            if event.keyCode == 53 { self.stopRecording(); self.shortcutNote = nil; return nil }
            guard let s = Shortcut.from(event: event) else {
                self.shortcutNote = "Додай хоча б одну з клавіш ⌘, ⌃ або ⌥ — інакше вона заважатиме друкувати"
                return nil
            }
            if let other = ShortcutAction.allCases.first(where: { $0 != action && self.shortcut($0) == s }) {
                self.shortcutNote = "\(s.label) уже стоїть на «\(other.title)»"
                return nil
            }
            self.save(s, for: action)
            self.stopRecording()
            self.shortcutNote = "Готово: «\(action.title)» — \(s.label)"
            return nil
        }
    }

    func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        if recordingShortcut != nil {
            recordingShortcut = nil
            onShortcutsChanged?()
        }
    }

    func resetShortcut(_ a: ShortcutAction) {
        save(a.defaultShortcut, for: a)
        shortcutNote = "Повернуто стандартну: \(a.defaultShortcut.label)"
    }

    private func save(_ s: Shortcut, for a: ShortcutAction) {
        shortcuts[a] = s
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: a.storageKey) }
        onShortcutsChanged?()
    }

    /// Частини панелі, які можна приховати в налаштуваннях («Що показувати»).
    enum Section: String, CaseIterable, Identifiable {
        case clips, downloads, mono, notes, calendar, timer, temperature, music, quick
        var id: String { rawValue }
        var title: String {
            switch self {
            case .clips: return "Буфер"
            case .downloads: return "Викачане"
            case .mono: return "Моно"
            case .notes: return "Мої нагадування"
            case .calendar: return "Календар"
            case .timer: return "Таймер"
            case .temperature: return "Температура"
            case .music: return "Музика"
            case .quick: return "Швидкі дії"
            }
        }
        var icon: String {
            switch self {
            case .clips: return "doc.on.clipboard"
            case .downloads: return "arrow.down.circle"
            case .mono: return "creditcard"
            case .notes: return "checklist"
            case .calendar: return "calendar"
            case .timer: return "timer"
            case .temperature: return "thermometer.medium"
            case .music: return "music.note"
            case .quick: return "square.grid.2x2"
            }
        }
        /// До якої вкладки належить (щоб піти з неї, якщо її сховали).
        var tab: Tab? {
            switch self {
            case .clips: return .clips
            case .downloads: return .downloads
            case .mono: return .mono
            case .notes: return .notes
            case .calendar: return .calendar
            case .temperature: return .system
            default: return nil
            }
        }
    }

    @Published private(set) var hiddenSections: Set<Section> =
        Set((UserDefaults.standard.stringArray(forKey: "hiddenSections") ?? []).compactMap(Section.init(rawValue:)))

    func isShown(_ s: Section) -> Bool { !hiddenSections.contains(s) }

    func setShown(_ s: Section, _ on: Bool) {
        withAnimation(Palette.spring) {
            if on { hiddenSections.remove(s) } else { hiddenSections.insert(s) }
            if !on, let t = s.tab, tab == t { tab = .home }
        }
        UserDefaults.standard.set(hiddenSections.map(\.rawValue), forKey: "hiddenSections")
        if s == .timer && !on { stopTimer() }
    }
    /// Панель усюди однієї висоти — як головна (компактно, і нічого не смикається).
    static let maxPanelHeight: CGFloat = 196

    @Published var tab: Tab = .home
    /// Відповідь Claude/Codex показується на весь розмір панелі.
    @Published var showAnswer = false
    var onRequestClose: (() -> Void)?
    @Published var hotKeyNote: String?

    // MARK: Буфер обміну
    let history = ClipboardHistory()
    @Published private(set) var clips: [ClipItem] = []
    @Published private(set) var clipCount = 0
    @Published var clipQuery = "" { didSet { refreshClips() } }
    @Published var justCopiedID: UUID?
    private var pruneTimer: Timer?

    // MARK: Спитати
    @Published var provider: AskProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "provider") }
    }
    @Published var prompt = ""
    @Published var askedPrompt = ""
    @Published var answer = ""
    @Published var askNote: String?
    @Published var isAsking = false
    @Published var answerCopied = false
    private var askTask: Task<Void, Never>?
    /// Кожне питання має свій номер: відповіді від зупиненого (старого) питання ігноруємо.
    private var askGeneration = 0
    private var claudeRun: ClaudeCodeRunner?
    private var codexRun: CodexRunner?
    private var geminiRun: GeminiCLIRunner?
    private var geminiModels: [String] = []
    /// Хто відповідав на останнє питання (перемикач моделі міг змінитися після).
    @Published private(set) var askedProvider: AskProvider = .opus
    let codexAvailable = CodexRunner.findExecutable() != nil

    /// За замовчуванням Opus і Fable йдуть через підписку (вбудований Claude Code), без ключа.
    @Published var useAPIKey = UserDefaults.standard.bool(forKey: "claudeViaAPI") {
        didSet { UserDefaults.standard.set(useAPIKey, forKey: "claudeViaAPI") }
    }
    var claudeViaSubscription: Bool { ClaudeCodeRunner.executable != nil && !useAPIKey }
    var needsAnthropicKey: Bool { provider.usesClaudeAPI && !claudeViaSubscription && !hasAnthropicKey }

    /// Gemini безкоштовно: через Gemini CLI (вхід Google-акаунтом) або через безкоштовний ключ AI Studio.
    let geminiCLIAvailable = GeminiCLIRunner.executable != nil
    @Published var geminiViaKey = UserDefaults.standard.bool(forKey: "geminiViaKey") {
        didSet { UserDefaults.standard.set(geminiViaKey, forKey: "geminiViaKey") }
    }
    var geminiUsesCLI: Bool { geminiCLIAvailable && !(geminiViaKey && hasGeminiKey) }
    var needsGeminiKey: Bool { provider == .gemini && !geminiUsesCLI && !hasGeminiKey }

    // MARK: Музика і система
    let nowPlaying = NowPlaying()
    let system = SystemMonitor()
    /// Яку картку монобанку показати (клік по картці — наступна).
    @Published var monoCardIndex = 0
    let calendar = CalendarStore()
    let downloads = DownloadsStore()

    // MARK: Мої нагадування (файл програми на цьому Mac)
    private let reminderStore = ReminderStore()
    @Published private(set) var reminders: [ReminderNote] = []
    @Published var newReminder = ""
    var openReminders: Int { reminders.filter { !$0.isDone }.count }

    func refreshReminders() { reminders = reminderStore.sorted }

    // MARK: Шаблони повідомлень
    private let templateStore = TemplateStore()
    @Published private(set) var templates: [Template] = []
    @Published var newTemplate = ""
    @Published var notesMode = 0  // 0 — нагадування, 1 — шаблони
    @Published private(set) var copiedTemplateID: UUID?

    func refreshTemplates() { templates = templateStore.items }

    func addTemplate() {
        guard templateStore.add(newTemplate) != nil else { return }
        newTemplate = ""
        withAnimation(Palette.spring) { refreshTemplates() }
    }

    func deleteTemplate(_ t: Template) {
        templateStore.delete(t.id)
        withAnimation(Palette.spring) { refreshTemplates() }
    }

    func copyTemplate(_ t: Template) {
        copyToPasteboard(t.text)
        copiedTemplateID = t.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.copiedTemplateID == t.id { self?.copiedTemplateID = nil }
        }
    }

    // MARK: Розумні дії, розкладка, текст із картинки

    func perform(_ action: SmartAction) {
        if let text = action.copyText { copyToPasteboard(text) }
        if let url = action.url { NSWorkspace.shared.open(url) }
    }

    func fixLayout(_ item: ClipItem) {
        copyToPasteboard(LayoutFix.convert(item.text))
    }

    @Published private(set) var recognizing = false

    /// Розпізнає текст на картинці й кладе його карткою в «Буфер».
    func recognizeText(in url: URL) {
        recognizing = true
        Task {
            let text = await ImageText.recognize(url)
            recognizing = false
            guard let text else {
                ocrNote = "На «\(url.lastPathComponent)» тексту не знайдено"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.ocrNote = nil }
                return
            }
            addClip(text, source: "Текст із картинки")
            if tab != .clips { select(.clips) }
        }
    }
    @Published var ocrNote: String?

    func handleDrop(_ urls: [URL]) {
        addToShelf(urls)
        for url in urls where ImageText.isImage(url) { recognizeText(in: url) }
        if tab != .clips { select(.clips) }
    }

    // MARK: Калькулятор

    var calcResult: Calculator.Result? { Calculator.evaluate(prompt) }

    /// «138 $ ≈ 5 740,80 ₴» або «900».
    func calcText(_ r: Calculator.Result) -> String {
        let main = Calculator.format(r.value)
        guard let cur = r.currency else { return main }
        if cur == 980 { return "\(main) ₴" }
        let sym = Monobank.currencySymbol(cur)
        if let rate = rates.first(where: { $0.currencyCodeA == cur })?.sell {
            return "\(main) \(sym) ≈ \(Calculator.format(r.value * rate)) ₴"
        }
        return "\(main) \(sym)"
    }

    @Published private(set) var calcCopied = false

    func copyCalc() {
        guard let r = calcResult else { return }
        copyToPasteboard(Calculator.format(r.value).replacingOccurrences(of: "\u{00a0}", with: ""))
        calcCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.calcCopied = false }
    }

    // MARK: «Не засинай» і пауза при дзвінку
    let awake = StayAwake()
    @Published var pauseOnCall = UserDefaults.standard.object(forKey: "pauseOnCall") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pauseOnCall, forKey: "pauseOnCall") }
    }

    // MARK: Бюджет на день (монобанк)
    @Published var monoBudget = UserDefaults.standard.integer(forKey: "monoBudget") {
        didSet { UserDefaults.standard.set(monoBudget, forKey: "monoBudget") }
    }
    @Published private(set) var monoMonth: [Monobank.Transaction] = []
    var budgetToday: Budget.Day? { Budget.compute(monthly: monoBudget, transactions: monoMonth) }

    func addReminder() {
        guard reminderStore.add(newReminder) != nil else { return }
        newReminder = ""
        withAnimation(Palette.spring) { refreshReminders() }
    }

    func toggleReminder(_ note: ReminderNote) {
        reminderStore.toggle(note.id)
        withAnimation(Palette.spring) { refreshReminders() }
    }

    func deleteReminder(_ note: ReminderNote) {
        reminderStore.delete(note.id)
        withAnimation(Palette.spring) { refreshReminders() }
    }

    func clearDoneReminders() {
        reminderStore.clearDone()
        withAnimation(Palette.spring) { refreshReminders() }
    }

    // MARK: Курс валют (відкриті дані монобанку)
    @Published private(set) var rates: [MonoCurrency.Rate] = []
    private var ratesAt: Date?

    // MARK: Полиця для файлів (лише посилання на файли, у пам'яті)
    struct ShelfItem: Identifiable, Equatable {
        let id = UUID()
        let url: URL
    }
    @Published private(set) var shelf: [ShelfItem] = []

    // MARK: Таймер
    @Published private(set) var timerEnd: Date?
    @Published private(set) var timerTitle = ""
    @Published var timerDone = false
    private var timerTick: Timer?
    var onTimerFinished: (() -> Void)?

    /// Підпис над відповіддю (наприклад, «Переклади: …»), якщо питання створене кнопкою.
    @Published var askedTitle: String?

    // MARK: Секрети (лише в Keychain + копія в пам'яті)
    @Published private(set) var hasAnthropicKey: Bool
    @Published private(set) var hasMonoToken: Bool
    @Published private(set) var hasGeminiKey: Bool
    @Published var editingSecret: SecretKind?
    @Published var secretError: String?
    private var cachedSecrets: [SecretKind: String] = [:]

    // MARK: Монобанк
    @Published private(set) var mono: Monobank.ClientInfo?
    @Published private(set) var monoStatement: [Monobank.Transaction] = []
    @Published private(set) var monoError: String?
    @Published private(set) var monoLoading = false
    @Published private(set) var monoUpdatedAt: Date?
    @Published var monoHidden = UserDefaults.standard.bool(forKey: "monoHidden") {
        didSet { UserDefaults.standard.set(monoHidden, forKey: "monoHidden") }
    }

    // MARK: Швидкі дії
    @Published private(set) var badges: [String: String] = [:]
    @Published private(set) var running: Set<String> = []
    @Published private(set) var badgesNeedPermission = false
    private var badgeTimer: Timer?

    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Мережеві запити без кешу на диску.
    private let session = URLSession(configuration: .ephemeral)

    init() {
        provider = AskProvider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .opus
        hasAnthropicKey = Keychain.exists(service: SecretKind.anthropic.service)
        templates = templateStore.items
        reminders = reminderStore.sorted
        hasMonoToken = Keychain.exists(service: SecretKind.monobank.service)
        hasGeminiKey = Keychain.exists(service: SecretKind.gemini.service)
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.history.prune() { self.refreshClips() }
            }
        }
    }

    // MARK: - Панель

    func panelDidOpen() {
        refreshClips()
        nowPlaying.panelDidOpen()
        system.start(interval: 3)
        refreshRates()
        calendar.reload()
        refreshBadges()
        badgeTimer?.invalidate()
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBadges() }
        }
        if tab == .mono { refreshMono() }
        if tab == .downloads { downloads.startWatching() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func panelDidClose() {
        nowPlaying.panelDidClose()
        downloads.stopWatching()
        system.stop()
        badgeTimer?.invalidate()
        badgeTimer = nil
        justCopiedID = nil
    }

    // MARK: - Буфер обміну

    func addClip(_ text: String, source: String?, bundleID: String? = nil) {
        if history.add(text, sourceApp: source, sourceBundleID: bundleID) { refreshClips() }
    }

    func refreshClips() {
        clips = history.search(clipQuery)
        clipCount = history.items.count
    }

    /// Три останні записи для віджета на головній.
    var recentClips: [ClipItem] { Array(history.items.prefix(3)) }

    func clearClips() {
        history.clear()
        clipQuery = ""
        refreshClips()
    }

    var pasteboardDenied: Bool {
        if #available(macOS 15.4, *) { return NSPasteboard.general.accessBehavior == .alwaysDeny }
        return false
    }

    func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func copyClip(_ item: ClipItem) {
        copyToPasteboard(item.text)
        justCopiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.onRequestClose?()
        }
    }

    // MARK: - Спитати Claude / Codex

    func ask() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if pendingTitle == nil, calcResult != nil { copyCalc(); return }  // це приклад — просто копіюємо результат
        guard !text.isEmpty, !isAsking else { return }
        askedPrompt = text
        askedTitle = pendingTitle
        pendingTitle = nil
        prompt = ""
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showAnswer = true }
        answer = ""
        askNote = nil
        answerCopied = false
        isAsking = true
        let provider = self.provider
        askedProvider = provider
        askGeneration += 1
        let gen = askGeneration
        askTask = Task { [weak self] in
            guard let self else { return }
            if provider == .codex {
                await self.askCodex(text, gen: gen)
            } else if provider == .gemini {
                if self.geminiUsesCLI { await self.askGeminiCLI(text, gen: gen) } else { await self.askGemini(text, gen: gen) }
            } else if self.claudeViaSubscription {
                await self.askClaudeCode(text, model: provider, gen: gen)
            } else {
                await self.askClaude(text, model: provider, gen: gen)
            }
            guard gen == self.askGeneration else { return }  // це питання вже зупинили
            self.isAsking = false
            Debug.log("відповідь (\(provider.title), \(provider == .gemini ? (self.geminiUsesCLI ? "CLI" : "ключ") : self.claudeViaSubscription ? "підписка" : "API")): \(self.answer.prefix(120)) \(self.askNote ?? "")")
        }
    }

    private var pendingTitle: String?

    /// «Переклади / Перепиши / Поясни» для запису з буфера.
    func askAbout(_ text: String, action: ClipAction) {
        guard !isAsking else { return }
        prompt = action.prompt(for: text)
        pendingTitle = "\(action.title): \(text.prefix(140))"
        select(.home)
        ask()
    }

    func stopAsking() {
        askGeneration += 1  // усе, що ще прийде від цього питання, — ігноруємо
        askTask?.cancel()
        codexRun?.cancel()
        claudeRun?.cancel()
        geminiRun?.cancel()
        isAsking = false
        if answer.isEmpty { askNote = "Зупинено." }
    }

    func newQuestion() {
        if isAsking { stopAsking() }
        prompt = ""
        askedPrompt = ""
        answer = ""
        askNote = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showAnswer = false }
    }

    /// Висота панелі залежить від того, що зараз показано.
    var panelHeight: CGFloat { Self.maxPanelHeight }

    func select(_ newTab: Tab) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            if newTab == .home && tab == .home { showAnswer = false }
            tab = newTab
            if editingSecret != nil { editingSecret = nil }
        }
        if newTab == .mono { refreshMono(); refreshRates() }
        if newTab == .calendar { calendar.reload() }
        if newTab == .downloads { downloads.startWatching() } else { downloads.stopWatching() }
    }

    func editSecret(_ kind: SecretKind?) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            if let kind { tab = kind == .monobank ? .mono : .home }
            editingSecret = kind
        }
    }

    private func askClaude(_ text: String, model: AskProvider, gen: Int) async {
        guard let key = secret(.anthropic) else {
            askNote = "Не вдалося прочитати ключ з Keychain. Додай його ще раз у меню ⚙︎."
            return
        }
        func current() -> Bool { gen == askGeneration }
        do {
            let request = try ClaudeAPI.makeRequest(prompt: text, model: model, apiKey: key)
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                var body = ""
                for try await line in bytes.lines {
                    body += line
                    if body.count > 20_000 { break }
                }
                let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
                let err = json?["error"] as? [String: Any]
                if current() {
                    askNote = ClaudeAPI.friendlyError(type: err?["type"] as? String, message: err?["message"] as? String, status: status)
                }
                return
            }
            for try await line in bytes.lines {
                if Task.isCancelled || !current() { break }
                switch ClaudeAPI.parseStreamLine(line) {
                case .text(let t): answer += t
                case .stop(let reason): askNote = ClaudeAPI.stopNote(reason)
                case .error(let message): askNote = message
                case nil: break
                }
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch let error as URLError where error.code == .notConnectedToInternet {
            if current() { askNote = "Немає інтернету." }
        } catch {
            if current() { askNote = "Не вдалося зв'язатися з Claude: \(error.localizedDescription)" }
        }
    }

    private func askClaudeCode(_ text: String, model: AskProvider, gen: Int) async {
        let runner = ClaudeCodeRunner()
        claudeRun = runner
        do {
            try await runner.run(prompt: text, model: model) { [weak self] event in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, gen == self.askGeneration else { return }
                        switch event {
                        case .text(let t): self.answer += t
                        case .stop(let reason): self.askNote = ClaudeAPI.stopNote(reason)
                        case .error(let message): self.askNote = message
                        }
                    }
                }
            }
        } catch is CancellationError {
        } catch {
            if gen == askGeneration { askNote = error.localizedDescription }
        }
    }

    private func askCodex(_ text: String, gen: Int) async {
        let runner = CodexRunner()
        codexRun = runner
        do {
            let result = try await runner.run(prompt: text)
            if gen == askGeneration { answer = result }
        } catch is CancellationError {
        } catch {
            if gen == askGeneration { askNote = error.localizedDescription }
        }
    }

    private func askGeminiCLI(_ text: String, gen: Int) async {
        let runner = GeminiCLIRunner()
        geminiRun = runner
        do {
            let result = try await runner.run(prompt: text)
            if gen == askGeneration { answer = result }
        } catch is CancellationError {
        } catch {
            if gen == askGeneration { askNote = error.localizedDescription }
        }
    }

    /// Gemini через безкоштовний ключ з AI Studio: відповідь приходить шматочками.
    private func askGemini(_ text: String, gen: Int) async {
        guard let key = secret(.gemini) else {
            askNote = "Не вдалося прочитати ключ Gemini з Keychain. Додай його ще раз у ⚙︎ → Claude."
            return
        }
        func current() -> Bool { gen == askGeneration }
        if geminiModels.isEmpty, let (data, resp) = try? await session.data(for: GeminiAPI.modelsRequest(apiKey: key)),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            geminiModels = GeminiAPI.pickModels(from: data)
        }
        let candidates = geminiModels.isEmpty ? [GeminiAPI.fallbackModel] : Array(geminiModels.prefix(2))
        do {
            for (i, model) in candidates.enumerated() {
                let (bytes, response) = try await session.bytes(for: GeminiAPI.makeRequest(prompt: text, model: model, apiKey: key))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status != 200 {
                    var body = ""
                    for try await line in bytes.lines {
                        body += line
                        if body.count > 20_000 { break }
                    }
                    // Найновіша модель перевантажена або недоступна безкоштовно — пробуємо попередню.
                    if [404, 429, 503].contains(status), i + 1 < candidates.count, current() { continue }
                    let err = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["error"] as? [String: Any]
                    if current() { askNote = GeminiAPI.friendlyError(status: status, message: err?["message"] as? String) }
                    return
                }
                Debug.log("gemini модель: \(model)")
                for try await line in bytes.lines {
                    if Task.isCancelled || !current() { break }
                    switch GeminiAPI.parseStreamLine(line) {
                    case .text(let t): answer += t
                    case .stop(let reason): askNote = ClaudeAPI.stopNote(reason)
                    case .error(let message): askNote = message
                    case nil: break
                    }
                }
                return
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch let error as URLError where error.code == .notConnectedToInternet {
            if current() { askNote = "Немає інтернету." }
        } catch {
            if current() { askNote = "Не вдалося зв'язатися з Gemini: \(error.localizedDescription)" }
        }
    }

    func copyAnswer() {
        copyToPasteboard(answer)
        answerCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.answerCopied = false }
    }

    func openInClaudeApp() {
        let q = askedPrompt.isEmpty ? prompt : askedPrompt
        if let url = ClaudeAPI.desktopURL(prompt: q),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let web = URL(string: "https://claude.ai/new") {
            NSWorkspace.shared.open(web)
        }
        onRequestClose?()
    }

    // MARK: - Секрети

    func hasSecret(_ kind: SecretKind) -> Bool {
        switch kind {
        case .anthropic: return hasAnthropicKey
        case .monobank: return hasMonoToken
        case .gemini: return hasGeminiKey
        }
    }

    /// Якщо Keychain не віддав секрет (натиснули «Заборонити»), не питаємо знову щоразу — лише на «Спробувати ще».
    private var secretReadFailed: Set<SecretKind> = []

    private func secret(_ kind: SecretKind, retry: Bool = false) -> String? {
        if let s = cachedSecrets[kind] { return s }
        if secretReadFailed.contains(kind) && !retry { return nil }
        let s = Keychain.read(service: kind.service)
        cachedSecrets[kind] = s
        if s == nil { secretReadFailed.insert(kind) } else { secretReadFailed.remove(kind) }
        return s
    }

    func saveSecret(_ kind: SecretKind, value raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        secretError = nil
        guard !value.isEmpty else { return }
        if kind == .anthropic && !value.hasPrefix("sk-ant-") {
            secretError = "Це не схоже на ключ Claude API (він починається з «sk-ant-»)."
            return
        }
        if kind == .gemini && !value.hasPrefix("AIza") {
            secretError = "Це не схоже на ключ Gemini (він починається з «AIza»)."
            return
        }
        guard Keychain.save(value, service: kind.service, label: kind.keychainLabel) else {
            secretError = "Не вдалося зберегти в Keychain."
            return
        }
        cachedSecrets[kind] = value
        secretReadFailed.remove(kind)
        setHas(kind, true)
        editSecret(nil)
        if kind == .monobank {
            resetMono()  // новий токен — інший рахунок: старі дані й пауза не діють
            refreshMono(force: true)
        }
    }

    func removeSecret(_ kind: SecretKind) {
        Keychain.delete(service: kind.service)
        cachedSecrets[kind] = nil
        secretReadFailed.remove(kind)
        setHas(kind, false)
        if kind == .monobank { resetMono() }
    }

    private func resetMono() {
        monoGeneration += 1
        mono = nil
        monoStatement = []
        monoMonth = []
        monoError = nil
        monoUpdatedAt = nil
        monoLastAttempt = nil
    }

    private func setHas(_ kind: SecretKind, _ value: Bool) {
        switch kind {
        case .anthropic: hasAnthropicKey = value
        case .monobank: hasMonoToken = value
        case .gemini: hasGeminiKey = value; geminiModels = []
        }
    }

    // MARK: - Монобанк (лише читання)

    /// Час останньої спроби (і вдалої, і з помилкою) — монобанк дозволяє один запит на хвилину.
    private var monoLastAttempt: Date?
    private var monoGeneration = 0

    var monoCooldownLeft: Int {
        guard let at = monoLastAttempt else { return 0 }
        return max(0, Int(Monobank.cooldown - Date().timeIntervalSince(at)))
    }

    func refreshMono(force: Bool = false) {
        guard hasMonoToken, !monoLoading else { return }
        if monoCooldownLeft > 0 {  // монобанк дозволяє запит раз на хвилину
            if force { monoError = "Монобанк дозволяє оновлення раз на хвилину — ще \(monoCooldownLeft) с" }
            return
        }
        guard let token = secret(.monobank, retry: force) else {
            monoError = "Не вдалося прочитати токен з Keychain. Натисни «Спробувати ще» й дозволь доступ."
            return
        }
        monoLoading = true
        monoError = nil
        monoLastAttempt = Date()
        let gen = monoGeneration
        Task {
            defer {
                monoLoading = false
                if gen != monoGeneration { refreshMono(force: true) }  // токен змінили, поки чекали — оновлюємо з новим
            }
            do {
                let info: Monobank.ClientInfo = try await fetchMono(Monobank.clientInfoRequest(token: token))
                guard gen == monoGeneration else { return }  // токен змінили чи видалили, поки чекали
                mono = info
                monoUpdatedAt = Date()
                if let main = Monobank.mainAccount(info.accounts) {
                    // З початку місяця (для бюджету), але щонайменше 7 днів.
                    let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
                    let from = min(monthStart, Date().addingTimeInterval(-7 * 86400))
                    let list: [Monobank.Transaction] = try await fetchMono(Monobank.statementRequest(token: token, account: main.id, from: from))
                    guard gen == monoGeneration else { return }
                    monoMonth = list
                    monoStatement = Array(list.sorted { $0.time > $1.time }.prefix(30))
                }
            } catch let e as MonoFailure {
                if gen == monoGeneration { monoError = e.message }
            } catch {
                if gen == monoGeneration { monoError = "Не вдалося отримати дані монобанку: \(error.localizedDescription)" }
            }
        }
    }

    private struct MonoFailure: Error { let message: String }

    private func fetchMono<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MonoFailure(message: Monobank.friendlyError(status: status)) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MonoFailure(message: "Монобанк відповів у незрозумілому форматі.")
        }
    }

    // MARK: - Курс валют

    func refreshRates() {
        if let at = ratesAt, Date().timeIntervalSince(at) < MonoCurrency.cacheTime, !rates.isEmpty { return }
        ratesAt = Date()
        Task {
            guard let (data, response) = try? await session.data(from: MonoCurrency.url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let all = try? JSONDecoder().decode([MonoCurrency.Rate].self, from: data) else {
                ratesAt = nil
                return
            }
            rates = MonoCurrency.pick(all)
        }
    }

    // MARK: - Полиця

    func addToShelf(_ urls: [URL]) {
        for url in urls where url.isFileURL && !shelf.contains(where: { $0.url == url }) {
            shelf.insert(ShelfItem(url: url), at: 0)
        }
        if shelf.count > 20 { shelf.removeLast(shelf.count - 20) }
    }

    func removeFromShelf(_ item: ShelfItem) { shelf.removeAll { $0 == item } }
    func clearShelf() { shelf.removeAll() }
    func revealInFinder(_ item: ShelfItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    // MARK: - Таймер

    var timerRemaining: TimeInterval? { timerEnd.map { $0.timeIntervalSinceNow } }

    func startTimer(minutes: Int, title: String) {
        timerEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
        timerTitle = title
        timerDone = false
        timerTick?.invalidate()
        timerTick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let end = self.timerEnd else { return }
                if end.timeIntervalSinceNow <= 0 { self.finishTimer() }
            }
        }
    }

    func stopTimer() {
        timerTick?.invalidate()
        timerTick = nil
        timerEnd = nil
    }

    private func finishTimer() {
        stopTimer()
        timerDone = true
        NSSound(named: "Glass")?.play()
        onTimerFinished?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.timerDone = false }
    }

    // MARK: - Швидкі дії

    func refreshBadges() {
        let apps = QuickApp.messengers
        var pids: [String: pid_t] = [:]
        for app in apps {
            if let r = NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first {
                pids[app.id] = r.processIdentifier
            }
        }
        running = Set(pids.keys)
        badgesNeedPermission = !DockBadges.isTrusted
        var paths: [String: String] = [:]  // шлях до програми → bundle id
        for app in apps { if let url = appURL(app.id) { paths[url.standardizedFileURL.path] = app.id } }
        Task.detached(priority: .utility) {
            var result: [String: String] = [:]
            // Основний спосіб (macOS 27): читаємо числа з Dock через «Універсальний доступ».
            for (path, label) in DockBadges.read() {
                if let id = paths[path] { result[id] = label }
            }
            // Запасний спосіб для старіших macOS.
            for (id, pid) in pids where result[id] == nil {
                if let label = Self.dockBadge(pid: pid) { result[id] = label }
            }
            await MainActor.run { [result] in self.badges = result }
        }
    }

    func requestBadgePermission() {
        DockBadges.requestPermission()
    }

    /// Число з іконки програми в Dock (те саме червоне коло).
    nonisolated private static func dockBadge(pid: pid_t) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        p.arguments = ["info", "-only", "StatusLabel", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return BadgeParser.parse(String(decoding: data, as: UTF8.self))
    }

    func appURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func openApp(_ bundleID: String) {
        guard let url = appURL(bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        onRequestClose?()
    }

    func openGmail() {
        NSWorkspace.shared.open(URL(string: "https://mail.google.com/mail/u/0/#inbox")!)
        onRequestClose?()
    }

    // MARK: - Автозапуск

    var launchNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    var badgesTrusted: Bool { DockBadges.isTrusted }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            hotKeyNote = "Не вдалося змінити автозапуск: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
