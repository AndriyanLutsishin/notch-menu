import AppKit
import EventKit
import NotchCore
import SwiftUI
import UniformTypeIdentifiers

/// Форма «продовження чубчика»: верх із загинами-«вушками» біля рамки екрана, великі заокруглення знизу.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let tr = min(topRadius, rect.width / 4, rect.height / 2)
        let br = max(0, min(bottomRadius, rect.height - tr, (rect.width - 2 * tr) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr), control: CGPoint(x: rect.minX + tr, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY), control: CGPoint(x: rect.minX + tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br), control: CGPoint(x: rect.maxX - tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

enum Palette {
    static let surface = Color.white.opacity(0.08)
    static let surfaceHover = Color.white.opacity(0.15)
    static let pill = Color.white.opacity(0.15)
    static let hairline = Color.white.opacity(0.12)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.38)
    static let accent = Color(red: 0.85, green: 0.47, blue: 0.34)  // теплий кораловий, як у Claude
    static let positive = Color(red: 0.42, green: 0.82, blue: 0.55)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.35)
    static let hot = Color(red: 1.0, green: 0.42, blue: 0.35)
    static let spring = Animation.spring(response: 0.4, dampingFraction: 0.85)
}

// MARK: - Корінь

struct PanelRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: PanelState
    @State private var dropTarget = false

    var body: some View {
        let w = state.expanded ? state.expandedWidth : state.notchSize.width
        let h = state.expanded ? model.panelHeight : state.notchSize.height
        let shape = NotchShape(topRadius: state.expanded ? state.expandedTopRadius : state.collapsedTopRadius,
                               bottomRadius: state.expanded ? 34 : 10)
        VStack(spacing: 0) {
            shape
                .fill(Color.black)
                .frame(width: w, height: h)
                .overlay(alignment: .top) {
                    if state.expanded {
                        PanelContent(model: model, state: state)
                            .frame(width: state.expandedWidth, height: model.panelHeight, alignment: .top)
                            .transition(state.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
                    }
                }
                .clipShape(shape)
                .overlay(shape.stroke(Palette.accent, lineWidth: dropTarget ? 2 : 0))
                .shadow(color: .black.opacity(state.expanded ? 0.45 : 0), radius: 18, y: 8)
                // Перетягнув файл на панель — він лягає на полицю (вкладка «Буфер»).
                .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in
                    for provider in providers {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            guard let url else { return }
                            DispatchQueue.main.async { model.handleDrop([url]) }
                        }
                    }
                    return true
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }
}

struct PanelContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: PanelState

    var body: some View {
        VStack(spacing: 0) {
            HeaderBand(model: model, state: state)
                .frame(height: state.notchSize.height)
            screen
                .padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(screenID)
                .transition(.opacity)
        }
        .padding(.horizontal, state.expandedTopRadius + 22)
        .padding(.bottom, 18)
    }

    private var screenID: String {
        "\(model.tab.rawValue)-\(model.showAnswer)-\(model.editingSecret?.rawValue ?? "")"
    }

    @ViewBuilder
    private var screen: some View {
        switch model.tab {
        case .home:
            if let kind = model.editingSecret, kind != .monobank {
                SecretSetupView(model: model, kind: kind)
            } else if model.showAnswer {
                AnswerView(model: model, state: state)
            } else {
                HomeView(model: model, state: state)
            }
        case .clips: ClipboardView(model: model)
        case .downloads: DownloadsView(model: model, store: model.downloads)
        case .mono: MonoView(model: model)
        case .notes:
            if model.notesMode == 0 { RemindersView(model: model) } else { TemplatesView(model: model) }
        case .system: SystemView(monitor: model.system)
        case .calendar: CalendarView(store: model.calendar)
        case .settings: SettingsView(model: model)
        case .visibility: VisibilityView(model: model)
        case .shortcuts: ShortcutsView(model: model)
        }
    }
}

// MARK: - Смуга біля чубчика: вкладки ліворуч, температура й шестерня праворуч

struct HeaderBand: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: PanelState

    var body: some View {
        let notchW = state.notchSize.width - state.collapsedTopRadius * 2
        let inner = state.expandedWidth - (state.expandedTopRadius + 22) * 2
        let side = max(120, (inner - notchW) / 2 - 8)
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                TabPill(title: "Головна", icon: "sparkles", tab: .home, model: model)
                if model.isShown(.clips) {
                    TabPill(title: "Буфер", icon: "doc.on.clipboard", tab: .clips, model: model, count: model.clipCount)
                }
                if model.isShown(.downloads) {
                    TabPill(title: "Викачане", icon: "arrow.down.circle", tab: .downloads, model: model)
                }
                if model.isShown(.mono) {
                    TabPill(title: "Моно", icon: "creditcard", tab: .mono, model: model)
                }
                if model.isShown(.notes) {
                    TabPill(title: "Мої нагадування", icon: "checklist", tab: .notes, model: model, count: model.openReminders)
                }
            }
            .frame(width: side, alignment: .leading)
            Spacer(minLength: notchW)
            HStack(spacing: 6) {
                if model.isAsking && !(model.tab == .home && model.showAnswer) {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("думає…").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                }
                if let note = model.hotKeyNote {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Palette.warning).help(note)
                }
                if model.timerDone {
                    Text("⏰ Час вийшов").font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(Palette.accent))
                        .fixedSize()
                } else if model.isShown(.calendar) {
                    CalendarChip(model: model, store: model.calendar)
                }
                if model.isShown(.timer) { TimerChip(model: model) }
                if model.isShown(.temperature) { TempChip(model: model, monitor: model.system) }
                SettingsMenu(model: model)
            }
            .frame(width: side, alignment: .trailing)
        }
    }
}

struct TabPill: View {
    let title: String
    let icon: String
    let tab: AppModel.Tab
    @ObservedObject var model: AppModel
    var count = 0
    @State private var hover = false

    var body: some View {
        let selected = model.tab == tab
        Button { model.select(tab) } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                // Назва — лише у вибраної вкладки, щоб усі вмістились біля чубчика.
                if selected { Text(title).font(.system(size: 13, weight: .semibold)) }
                if count > 0 {
                    Text("\(count)").font(.system(size: 10, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                }
            }
            .padding(.horizontal, selected ? 10 : 8).padding(.vertical, 5)
            .background(Capsule().fill(selected ? Palette.pill : (hover ? Palette.surface : .clear)))
            .foregroundStyle(selected ? .white : .white.opacity(0.8))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(title)
    }
}

/// «🌡 52°» біля чубчика — клік відкриває екран «Система».
struct TempChip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: SystemMonitor
    @State private var hover = false

    var body: some View {
        let selected = model.tab == .system
        Button { model.select(selected ? .home : .system) } label: {
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium").font(.system(size: 11, weight: .semibold))
                Text(monitor.temps.cpu.map { "\(Int($0.rounded()))°" } ?? "—")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(selected ? Palette.pill : (hover ? Palette.surface : .clear)))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Температура процесора. Клік — усі показники системи")
    }

    private var tint: Color {
        guard let t = monitor.temps.cpu else { return .white }
        return t >= 85 ? Palette.hot : t >= 70 ? Palette.warning : .white
    }
}

/// Найближча подія сьогодні (або дата) — клік відкриває тиждень.
struct CalendarChip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: CalendarStore
    @State private var hover = false

    var body: some View {
        let selected = model.tab == .calendar
        Button { model.select(selected ? .home : .calendar) } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(selected ? Palette.pill : (hover ? Palette.surface : .clear)))
            .contentShape(Capsule())
            .frame(maxWidth: 118)
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(store.nextEventToday.map { "Наступна подія: \($0.title ?? "")" } ?? "Календар на тиждень")
    }

    private var label: String {
        if let e = store.nextEventToday {
            return "\(e.startDate.formatted(date: .omitted, time: .shortened)) \(e.title ?? "")"
        }
        return Date().formatted(.dateTime.weekday(.abbreviated).day()).capitalized
    }
}

/// Таймер: без запуску — значок; під час відліку — «24:13». Клік — меню з варіантами.
struct TimerChip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(FocusTimer.presets, id: \.minutes) { preset in
                Button(preset.title) { model.startTimer(minutes: preset.minutes, title: preset.title) }
            }
            if model.timerEnd != nil {
                Divider()
                Button("Зупинити таймер") { model.stopTimer() }
            }
            Divider()
            Section("Не засинати (екран і Mac)") {
                Button("30 хвилин") { model.awake.start(minutes: 30) }
                Button("1 година") { model.awake.start(minutes: 60) }
                Button("2 години") { model.awake.start(minutes: 120) }
                Button("Поки не вимкну") { model.awake.start(minutes: nil) }
                if model.awake.active { Button("Дозволити засинати") { model.awake.stop() } }
            }
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 4) {
                    if model.awake.active {
                        Image(systemName: "cup.and.saucer.fill").foregroundStyle(Palette.positive)
                    }
                    Image(systemName: model.timerEnd == nil ? "timer" : "timer.circle.fill")
                    if let left = model.timerRemaining {
                        Text(FocusTimer.format(remaining: left)).monospacedDigit()
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.timerEnd == nil ? Color.white : Palette.accent)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.awake.active ? "Mac не засне\(model.awake.until.map { " до \($0.formatted(date: .omitted, time: .shortened))" } ?? ", поки не вимкнеш")"
              : (model.timerEnd == nil ? "Таймер / Pomodoro · «Не засинати»" : model.timerTitle))
    }
}

/// Шестерня: відкриває екран налаштувань (повторний клік — назад на головну).
struct SettingsMenu: View {
    @ObservedObject var model: AppModel
    @State private var hover = false

    var body: some View {
        let selected = model.tab == .settings
        Button { model.select(selected ? .home : .settings) } label: {
            Image(systemName: "gearshape.fill").font(.system(size: 14))
                .frame(width: 28, height: 28)
                .background(Circle().fill(selected ? Palette.pill : (hover ? Palette.surface : .clear)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Налаштування")
    }
}

/// Тонка вертикальна лінія між віджетами.
struct WidgetDivider: View {
    var body: some View {
        Rectangle().fill(Palette.hairline).frame(width: 1)
            .padding(.vertical, 4)
            .padding(.horizontal, 18)
    }
}

/// Маленький сірий заголовок над віджетом.
struct WidgetTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
    }
}

// MARK: - Головна: музика | Claude | швидкі дії

struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: PanelState

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if model.isShown(.music) {
                MusicWidget(player: model.nowPlaying)
                    .frame(width: 262, alignment: .leading)
                WidgetDivider()
            }
            ClaudeWidget(model: model, state: state)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            if model.isShown(.quick) {
                WidgetDivider()
                QuickGrid(model: model)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct ClaudeWidget: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: PanelState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(AskProvider.allCases) { p in
                    ProviderChip(provider: p, selected: model.provider == p) {
                        model.provider = p
                        focusSoon()
                    }
                }
                Spacer(minLength: 0)
            }

            if model.needsAnthropicKey {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Щоб питати Opus і Fable, додай ключ Claude API — один раз.")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PillButton(title: "Додати ключ", icon: "key.fill", prominent: true) { model.editSecret(.anthropic) }
                }
            } else if model.needsGeminiKey {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gemini безкоштовний: візьми ключ в AI Studio (вхід через Google) — один раз.")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PillButton(title: "Додати ключ Gemini", icon: "key.fill", prominent: true) { model.editSecret(.gemini) }
                }
            } else if model.provider == .codex && !model.codexAvailable {
                Text("Codex не знайдено на цьому Mac.").font(.callout).foregroundStyle(Palette.warning)
            } else {
                inputField
            }

            if let r = model.calcResult {
                HStack(spacing: 8) {
                    Text("= \(model.calcText(r))").font(.system(size: 14, weight: .bold).monospacedDigit())
                        .foregroundStyle(model.calcCopied ? Palette.positive : Palette.accent)
                    Text(model.calcCopied ? "✓ скопійовано" : "Enter — скопіювати")
                        .font(.system(size: 11)).foregroundStyle(model.calcCopied ? Palette.positive : Palette.tertiary)
                }
            } else {
            HStack(spacing: 6) {
                Text(model.provider == .codex ? "Через підписку ChatGPT · Enter — надіслати"
                     : model.provider == .gemini ? (model.geminiUsesCLI ? "Безкоштовно через Gemini CLI · Enter — надіслати"
                                                    : "Безкоштовно через ключ Gemini · Enter — надіслати")
                     : model.claudeViaSubscription ? "Через підписку Claude · Enter — надіслати"
                     : "Через ключ API · Enter — надіслати")
                    .foregroundStyle(Palette.tertiary)
                Spacer(minLength: 0)
                if !model.answer.isEmpty || model.isAsking {
                    Button {
                        withAnimation(Palette.spring) { model.showAnswer = true }
                    } label: {
                        Text(model.isAsking ? "Відповідь пишеться →" : "Остання відповідь →")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                }
            }
            .font(.system(size: 11))
            }
        }
        .onAppear { focusSoon() }
        .onChange(of: state.focusToken) { _, _ in focusSoon() }
    }

    private var inputField: some View {
        let canSend = !model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 6) {
            TextField("Спитай \(model.provider.title)…", text: $model.prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...2)
                .focused($focused)
                .focusEffectDisabled()
                .onSubmit { model.ask() }
                .padding(.vertical, 7)
            Button { model.ask() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(canSend ? Palette.accent : Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend || model.isAsking)
            .help("Надіслати (Enter)")
        }
        .padding(.leading, 14).padding(.trailing, 5).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 18).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(focused ? Palette.accent.opacity(0.6) : .clear, lineWidth: 1))
    }

    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
    }
}

struct ProviderChip: View {
    let provider: AskProvider
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    private var icon: String {
        switch provider {
        case .opus: return "sparkle"
        case .fable: return "wand.and.stars"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "diamond"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(provider.shortTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(selected ? Palette.pill : (hover ? Palette.surface : .clear)))
            .foregroundStyle(selected ? .white : Palette.secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(provider == .fable ? "Найсильніша модель" : provider == .codex ? "Codex через підписку ChatGPT"
              : provider == .gemini ? "Gemini від Google — безкоштовно" : "Швидка й розумна")
    }
}

/// Круглі кнопки, круглі: Gmail і месенджери з лічильником пропущених.
struct QuickGrid: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let apps = QuickApp.messengers.filter { model.appURL($0.id) != nil }
        VStack(spacing: 0) {
            LazyVGrid(columns: [GridItem(.fixed(52), spacing: 10), GridItem(.fixed(52))], spacing: 8) {
                RoundAction(help: "Відкрити Gmail", badge: nil, dimmed: false) {
                    model.openGmail()
                } label: {
                    Image(systemName: "envelope.fill").font(.system(size: 19))
                }
                ForEach(apps) { app in
                    let badge = model.badges[app.id]
                    RoundAction(help: helpText(app, badge: badge), badge: badge, dimmed: !model.running.contains(app.id)) {
                        model.openApp(app.id)
                    } label: {
                        if let url = model.appURL(app.id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 30, height: 30)
                        }
                    }
                }
            }
            .frame(width: 114)
            if model.badgesNeedPermission {
                Button { model.requestBadgePermission() } label: {
                    Label("Лічильники пропущених", systemImage: "bell.badge")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .help("Потрібен дозвіл «Універсальний доступ», щоб читати червоні числа з іконок у Dock")
                .padding(.top, 4)
            }
        }
    }

    private func helpText(_ app: QuickApp, badge: String?) -> String {
        if let badge { return "\(app.name): пропущених — \(badge)" }
        return model.running.contains(app.id) ? "\(app.name): нових немає" : "Відкрити \(app.name)"
    }
}

struct RoundAction<Label: View>: View {
    let help: String
    let badge: String?
    let dimmed: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            label()
                .opacity(dimmed ? 0.6 : 1)
                .frame(width: 52, height: 52)
                .background(Circle().fill(hover ? Palette.surfaceHover : Palette.surface))
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 3, y: -2)
                    }
                }
                .contentShape(Circle())
                .scaleEffect(hover ? 1.04 : 1)
                .animation(.easeOut(duration: 0.12), value: hover)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

// MARK: - Музика: «Зараз грає»

struct MusicWidget: View {
    @ObservedObject var player: NowPlaying

    var body: some View {
        HStack(spacing: 14) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                if player.hasTrack {
                    Text(player.title ?? "").font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    if let album = player.album, !album.isEmpty {
                        Text(album).font(.system(size: 13)).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                    if let artist = player.artist, !artist.isEmpty {
                        Text(artist).font(.system(size: 13)).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                } else {
                    Text("Нічого не грає").font(.system(size: 15, weight: .semibold))
                    Button("Відкрити \(player.source.title)") { player.openSource() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.accent)
                }
                Spacer(minLength: 6)
                if isYouTube && !player.youtubeControls {
                    PillButton(title: "До вкладки", icon: "arrow.up.forward.app") { player.showYouTubeMusicTab() }
                        .help("Щоб бачити трек і кнопки: дозволь «Універсальний доступ» (⚙︎) і тримай вкладку YouTube Music активною у своєму вікні Chrome")
                } else {
                    HStack(spacing: 20) {
                        controlButton("backward.fill", help: "Попередній трек") { player.previous() }
                        controlButton(playIcon, help: "Грати / пауза", size: 19) { player.playPause() }
                        controlButton("forward.fill", help: "Наступний трек") { player.next() }
                    }
                    .padding(.leading, 2)
                }
                if let need = player.needsPermission {
                    Button("Дозволити керування \(need)") { player.openPrivacySettings() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.warning)
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 112)
        .padding(.top, 4)
    }

    private var playIcon: String {
        switch player.isPlaying {
        case true?: return "pause.fill"
        case false?: return "play.fill"
        case nil: return player.hasTrack ? "playpause.fill" : "play.fill"
        }
    }

    private var isYouTube: Bool { player.source == .youtubeMusic }

    private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let art = player.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: isYouTube
                                   ? [Color(red: 0.95, green: 0.12, blue: 0.12), Color(red: 0.45, green: 0.05, blue: 0.08)]
                                   : [Color(red: 0.98, green: 0.28, blue: 0.38), Color(red: 0.55, green: 0.18, blue: 0.62)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: isYouTube ? "play.circle.fill" : "music.note")
                            .font(.system(size: 32, weight: .semibold)).foregroundStyle(.white.opacity(0.92)))
                }
            }
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(player.hasTrack ? 1 : 0.55)

            // Значок джерела: клік перемикає Apple Music ⇄ YouTube Music.
            Button {
                player.source = isYouTube ? .appleMusic : .youtubeMusic
            } label: {
                Group {
                    if isYouTube {
                        Image(systemName: "play.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color(red: 1, green: 0, blue: 0)))
                    } else if let icon = player.sourceIcon {
                        Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                    }
                }
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .help("Джерело: \(player.source.title). Клік — перемкнути на \(isYouTube ? "Apple Music" : "YouTube Music")")
            .offset(x: 6, y: 6)
        }
        .frame(width: 110, height: 110, alignment: .topLeading)
    }

    private func controlButton(_ icon: String, help: String, size: CGFloat = 15, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Відповідь (у тій самій висоті: питання | відповідь | кнопки)

struct AnswerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: PanelState

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(Palette.spring) { model.showAnswer = false }
                    } label: {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Palette.surface))
                    }
                    .buttonStyle(.plain)
                    .help("Назад на головну")
                    Text(model.askedProvider.title)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Palette.pill))
                    if model.isAsking { ProgressView().controlSize(.mini) }
                }
                Text(model.askedTitle ?? model.askedPrompt)
                    .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    .lineLimit(4)
            }
            .frame(width: 190, alignment: .topLeading)

            WidgetDivider()

            Group {
                if model.isAsking && model.answer.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(model.askedProvider.title) думає…").foregroundStyle(Palette.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(markdown(model.answer))
                                .font(.system(size: 13.5))
                                .lineSpacing(2)
                                .textSelection(.enabled)
                            if let note = model.askNote {
                                Text(note).font(.system(size: 12)).foregroundStyle(Palette.warning)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            WidgetDivider()

            VStack(alignment: .leading, spacing: 6) {
                if model.isAsking {
                    PillButton(title: "Зупинити", icon: "stop.fill") { model.stopAsking() }
                } else if !model.answer.isEmpty {
                    PillButton(title: model.answerCopied ? "Скопійовано" : "Копіювати",
                               icon: model.answerCopied ? "checkmark" : "doc.on.doc", prominent: true) { model.copyAnswer() }
                    PillButton(title: "У Claude", icon: "arrow.up.forward.app") { model.openInClaudeApp() }
                }
                PillButton(title: "Нове", icon: "plus") {
                    model.newQuestion()
                    state.focusToken += 1
                }
            }
            .frame(width: 118, alignment: .topLeading)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

// MARK: - Спільні кнопки

struct PillButton: View {
    let title: String
    let icon: String
    var prominent = false
    let action: () -> Void
    @State private var hover = false
    @State private var flashed = false

    var body: some View {
        Button {
            action()
            withAnimation(.easeOut(duration: 0.15)) { flashed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { flashed = false } }
        } label: {
            Label(title, systemImage: flashed ? "checkmark" : icon)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(flashed ? Palette.positive.opacity(0.85)
                                           : prominent ? Palette.accent.opacity(hover ? 1 : 0.85)
                                           : (hover ? Palette.surfaceHover : Palette.surface)))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct IconButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: 26, height: 26)
                .background(Circle().fill(hover ? Palette.surfaceHover : Palette.surface))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

// MARK: - Введення ключа / токена (компактно)

struct SecretSetupView: View {
    @ObservedObject var model: AppModel
    let kind: SecretKind
    @State private var value = ""

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: "key.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text(explanation)
                    .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(link.title) { NSWorkspace.shared.open(URL(string: link.url)!) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.accent)
            }
            .frame(width: 330, alignment: .topLeading)

            WidgetDivider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SecureField(kind == .anthropic ? "sk-ant-…" : kind == .gemini ? "AIza…" : "Встав токен монобанку", text: $value)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { save() }
                    Button("Зберегти", action: save)
                        .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let err = model.secretError {
                    Text(err).font(.system(size: 11.5)).foregroundStyle(Palette.warning)
                }
                HStack {
                    if kind != .monobank || model.hasSecret(kind) {
                        Button("Скасувати") { model.editSecret(nil) }
                    }
                    if model.hasSecret(kind) {
                        Button("Видалити збережений", role: .destructive) {
                            model.removeSecret(kind)
                            model.editSecret(nil)
                        }
                    }
                }
                Text("Лише у «Зв'язці ключів» macOS — не у файлах і не в історії буфера.")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var title: String {
        switch kind {
        case .anthropic: return "Ключ Claude API"
        case .monobank: return "Підключити монобанк"
        case .gemini: return "Безкоштовний ключ Gemini"
        }
    }

    private var link: (title: String, url: String) {
        switch kind {
        case .anthropic: return ("console.anthropic.com → API Keys", "https://console.anthropic.com/settings/keys")
        case .monobank: return ("Відкрити api.monobank.ua", "https://api.monobank.ua/")
        case .gemini: return ("aistudio.google.com → Get API key", "https://aistudio.google.com/apikey")
        }
    }

    private var explanation: String {
        switch kind {
        case .gemini:
            return "Увійди в AI Studio через Google, натисни «Create API key», скопіюй ключ і встав праворуч. Безкоштовно, без картки. Зауваж: на безкоштовному рівні Google може використовувати питання для навчання моделей."
        case .anthropic:
            return "Потрібен, лише якщо хочеш питати через API замість підписки. Оплата API окрема."
        case .monobank:
            return "Увійди на api.monobank.ua через QR у застосунку банку, скопіюй токен і встав праворуч. Токен дає лише перегляд — переказати ним гроші неможливо."
        }
    }

    private func save() {
        model.saveSecret(kind, value: value)
        if model.secretError == nil { value = "" }
    }
}

// MARK: - Буфер: стрічка карток

struct ClipboardView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Ліворуч — що це і як користуватись.
            VStack(alignment: .leading, spacing: 6) {
                Text("Буфер обміну").font(.system(size: 14, weight: .bold))
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    TextField("Пошук у скопійованому", text: $model.clipQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($searchFocused)
                        .focusEffectDisabled()
                }
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(Palette.surface))
                Button { model.clearClips() } label: {
                    Label("Очистити все скопійоване", systemImage: "trash").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Palette.secondary)
                .disabled(model.clipCount == 0)
                .opacity(model.clipCount == 0 ? 0.4 : 1)
            }
            .frame(width: 196, alignment: .topLeading)

            WidgetDivider()

            VStack(alignment: .leading, spacing: 5) {
                // Підписи розділів.
                HStack(spacing: 12) {
                    if !model.shelf.isEmpty {
                        Label("Полиця · \(model.shelf.count)", systemImage: "tray.full")
                            .help("Файли, які ти перетягнув на чубчик")
                    }
                    Label("Скопійоване · \(model.clips.count)", systemImage: "doc.on.clipboard")
                    Spacer(minLength: 4)
                    if model.recognizing {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Розпізнаю текст на картинці…") }
                    } else if let note = model.ocrNote {
                        Label(note, systemImage: "text.viewfinder").foregroundStyle(Palette.warning)
                    }
                    if model.pasteboardDenied {
                        Label("macOS не дає читати буфер", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.warning)
                            .help("Дозволь у Системних параметрах → Конфіденційність і безпека → Вставлення з інших програм")
                    }
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)

                if model.clips.isEmpty && model.shelf.isEmpty {
                    VStack(spacing: 5) {
                        Text(model.clipQuery.isEmpty ? "Скопіюй будь-який текст (⌘C) — він з'явиться тут" : "Нічого не знайдено")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.secondary)
                        Text("А файл можна перетягнути прямо на чубчик — він полежить на полиці")
                            .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.shelf) { item in
                                    FileCard(item: item, model: model)
                                }
                                ForEach(model.clips) { item in
                                    ClipCard(item: item, now: context.date, copied: model.justCopiedID == item.id,
                                             action: { model.copyClip(item) },
                                             onAsk: { model.askAbout(item.text, action: $0) },
                                             onLayout: { model.fixLayout(item) },
                                             onSmart: { model.perform($0) })
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { model.refreshClips(); searchFocused = true }
    }
}

/// Кнопка дії зі словами (для карток при наведенні). Після натискання — зелена «Готово».
struct CardActionButton: View {
    let title: String
    let icon: String
    var claude = false
    var compact = false
    /// Стан «уже зроблено» (наприклад, файл уже на полиці) — кнопка лишається зеленою.
    var persistentDone = false
    let action: () -> Void
    @State private var hover = false
    @State private var flashed = false

    var body: some View {
        let done = flashed || persistentDone
        Button {
            guard !persistentDone else { return }
            action()
            withAnimation(.easeOut(duration: 0.15)) { flashed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { withAnimation { flashed = false } }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: done ? "checkmark" : icon).font(.system(size: 10, weight: .bold)).frame(width: 13)
                    .foregroundStyle(claude && !done ? Palette.accent : .white)
                Text(flashed ? "Готово" : title).font(.system(size: compact ? 10.5 : 11.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 1)
                if claude && !done && !compact {
                    Image(systemName: "sparkle").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, compact ? 6 : 8)
            .frame(height: 21)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(done ? Palette.positive.opacity(0.85) : Color.white.opacity(hover ? 0.22 : 0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Картка скопійованого: програма-джерело, тип, текст; при наведенні — дії зі словами.
struct ClipCard: View {
    let item: ClipItem
    let now: Date
    let copied: Bool
    let action: () -> Void
    let onAsk: (ClipAction) -> Void
    var onLayout: () -> Void = {}
    var onSmart: (SmartAction) -> Void = { _ in }
    @State private var hover = Debug.forceHover

    var body: some View {
        let kind = item.kind
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                sourceIcon
                Text(item.sourceApp ?? kind.title).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Palette.secondary).lineLimit(1)
                Spacer(minLength: 2)
                Text(ago).font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.tertiary)
            }
            content(kind)
            Spacer(minLength: 0)
            Label(kind.title, systemImage: kind.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint.opacity(0.95))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(0.16)))
        }
        .padding(10)
        .frame(width: 236, height: 106, alignment: .topLeading)
        .opacity(hover && !copied ? 0 : 1)
        .overlay {
            if hover && !copied {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible())], spacing: 4) {
                    CardActionButton(title: "Скопіювати", icon: "doc.on.doc", compact: true, action: action)
                    CardActionButton(title: "Розкладка", icon: "keyboard", compact: true, action: onLayout)
                    CardActionButton(title: "Перекласти", icon: ClipAction.translate.icon, claude: true, compact: true) { onAsk(.translate) }
                    CardActionButton(title: "Переписати", icon: ClipAction.rewrite.icon, claude: true, compact: true) { onAsk(.rewrite) }
                    CardActionButton(title: "Пояснити", icon: ClipAction.explain.icon, claude: true, compact: true) { onAsk(.explain) }
                    if let smart = SmartAction.detect(item.text) {
                        CardActionButton(title: smart.title, icon: smart.icon, compact: true) { onSmart(smart) }
                    }
                }
                .padding(7)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.14), Color.white.opacity(0.04)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(copied ? Palette.positive : Color.white.opacity(hover ? 0.2 : 0.08), lineWidth: copied ? 1.5 : 1))
        .overlay(alignment: .center) {
            if copied {
                Label("Скопійовано", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Palette.positive.opacity(0.9)))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(String(item.text.prefix(400)))
    }

    @ViewBuilder
    private func content(_ kind: ClipKind) -> some View {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .link(let host):
            VStack(alignment: .leading, spacing: 2) {
                Text(host).font(.system(size: 14, weight: .bold)).lineLimit(1)
                Text(text).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
        case .code:
            Text(text).font(.system(size: 11, design: .monospaced)).lineLimit(2)
        case .number, .phone:
            Text(text).font(.system(size: 20, weight: .bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
        default:
            Text(text).font(.system(size: 12.5)).lineLimit(2)
        }
    }

    private var tint: Color {
        switch item.kind {
        case .link: return Color(red: 0.35, green: 0.6, blue: 1.0)
        case .email: return Color(red: 0.45, green: 0.8, blue: 0.95)
        case .code: return Color(red: 0.7, green: 0.5, blue: 1.0)
        case .number, .phone: return Palette.positive
        case .text: return Palette.accent
        }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        if let id = item.sourceBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: item.kind.icon).font(.system(size: 10)).foregroundStyle(Palette.secondary).frame(width: 16, height: 16)
        }
    }

    private var ago: String {
        let m = Int(now.timeIntervalSince(item.copiedAt) / 60)
        return m < 1 ? "щойно" : "\(m) хв тому"
    }
}

/// Файл на полиці: при наведенні — що з ним можна зробити.
struct FileCard: View {
    let item: AppModel.ShelfItem
    @ObservedObject var model: AppModel
    @State private var hover = Debug.forceHover

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable().frame(width: 46, height: 46)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            Text(item.url.lastPathComponent)
                .font(.system(size: 11, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
        }
        .padding(8)
        .frame(width: 128, height: 106)
        .opacity(hover ? 0 : 1)
        .overlay {
            if hover {
                VStack(spacing: 3) {
                    Text("Перетягни кудись,\nщоб вставити").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                    CardActionButton(title: "У Finder", icon: "folder") { model.revealInFinder(item) }
                    if ImageText.isImage(item.url) {
                        CardActionButton(title: "Текст з фото", icon: "text.viewfinder") { model.recognizeText(in: item.url) }
                    }
                    CardActionButton(title: "Прибрати", icon: "xmark") { model.removeFromShelf(item) }
                }
                .padding(8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.white.opacity(0.22)))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help("Файл на полиці (сам файл лишається на своєму місці)")
    }
}

// MARK: - Моно: картка, банки, операції — за мотивами застосунку монобанку

struct MonoView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if !model.hasMonoToken || model.editingSecret == .monobank {
            SecretSetupView(model: model, kind: .monobank)
        } else if let info = model.mono {
            content(info)
        } else {
            VStack(spacing: 8) {
                if model.monoLoading { ProgressView().controlSize(.small) }
                Text(model.monoError ?? "Завантажую дані монобанку…")
                    .font(.system(size: 13)).foregroundStyle(model.monoError == nil ? Palette.secondary : Palette.warning)
                if model.monoError != nil {
                    PillButton(title: "Спробувати ще", icon: "arrow.clockwise") { model.refreshMono(force: true) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { model.refreshMono() }
        }
    }

    private func sortedCards(_ info: Monobank.ClientInfo) -> [Monobank.Account] {
        info.accounts.sorted {
            ($0.currencyCode == 980 ? 0 : 1, $0.type == "black" ? 0 : 1, -$0.balance)
                < ($1.currencyCode == 980 ? 0 : 1, $1.type == "black" ? 0 : 1, -$1.balance)
        }
    }

    private func content(_ info: Monobank.ClientInfo) -> some View {
        let cards = sortedCards(info)
        let card = cards.isEmpty ? nil : cards[model.monoCardIndex % cards.count]
        return HStack(alignment: .top, spacing: 0) {
            if let card {
                MonoCard(account: card, hidden: model.monoHidden, index: model.monoCardIndex % max(cards.count, 1), total: cards.count,
                         budget: card.id == Monobank.mainAccount(info.accounts)?.id ? model.budgetToday : nil) {
                    withAnimation(Palette.spring) { model.monoCardIndex += 1 }
                }
            }
            if let jars = info.jars, !jars.isEmpty {
                WidgetDivider()
                MonoJars(jars: Array(jars.prefix(3)), hidden: model.monoHidden)
            }
            WidgetDivider()
            MonoOperations(model: model)
        }
        .onAppear { model.refreshMono(); model.refreshRates() }
    }
}

/// Картка: чорний градієнт, тип і останні цифри, великий баланс.
struct MonoCard: View {
    let account: Monobank.Account
    let hidden: Bool
    let index: Int
    let total: Int
    var budget: Budget.Day? = nil
    let next: () -> Void

    var body: some View {
        Button(action: next) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(account.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    if total > 1 {
                        HStack(spacing: 3) {
                            ForEach(0..<min(total, 5), id: \.self) { i in
                                Circle().fill(.white.opacity(i == index ? 0.9 : 0.3)).frame(width: 4, height: 4)
                            }
                        }
                    }
                }
                Spacer(minLength: 4)
                Text(Monobank.formatMoney(account.balance, currency: account.currencyCode))
                    .font(.system(size: 24, weight: .bold).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .blur(radius: hidden ? 8 : 0)
                if account.creditLimit > 0 {
                    Text("власні \(Monobank.formatMoney(account.ownMoney, currency: account.currencyCode))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .blur(radius: hidden ? 6 : 0)
                } else {
                    Text("баланс").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
                if let b = budget {
                    HStack(spacing: 5) {
                        Circle().fill(b.level == 0 ? Palette.positive : b.level == 1 ? Palette.warning : Palette.hot)
                            .frame(width: 7, height: 7)
                        Text(b.leftToday >= 0
                             ? "сьогодні ще \(Monobank.formatMoney(b.leftToday, currency: 980))"
                             : "перевищено на \(Monobank.formatMoney(-b.leftToday, currency: 980))")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .blur(radius: hidden ? 6 : 0)
                    }
                    .padding(.top, 3)
                    .help(hidden ? "Суми приховано (значок ока)"
                          : "Витрачено цього місяця: \(Monobank.formatMoney(b.spentMonth, currency: 980)) · сьогодні: \(Monobank.formatMoney(b.spentToday, currency: 980))")
                }
            }
            .padding(14)
            .frame(width: 214, height: 120, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .help(total > 1 ? "Клік — наступна картка" : account.title)
    }

    private var gradient: [Color] {
        switch account.type {
        case "white": return [Color(white: 0.85), Color(white: 0.55)]
        case "platinum": return [Color(white: 0.55), Color(white: 0.25)]
        case "iron": return [Color(white: 0.45), Color(white: 0.18)]
        case "yellow": return [Color(red: 0.98, green: 0.78, blue: 0.2), Color(red: 0.85, green: 0.5, blue: 0.1)]
        case "fop": return [Color(red: 0.2, green: 0.25, blue: 0.4), Color(red: 0.08, green: 0.1, blue: 0.2)]
        default: return [Color(white: 0.2), Color(white: 0.05)]
        }
    }
}

/// Банки — кільця прогресу до цілі.
struct MonoJars: View {
    let jars: [Monobank.Jar]
    let hidden: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitle(text: "Банки")
            HStack(alignment: .top, spacing: 12) {
                ForEach(jars) { jar in
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.12), lineWidth: 5)
                            Circle()
                                .trim(from: 0, to: jar.progress ?? 0)
                                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("🫙").font(.system(size: 18))
                        }
                        .frame(width: 50, height: 50)
                        Text(jar.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                        Text(Monobank.formatMoney(jar.balance, currency: jar.currencyCode))
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .blur(radius: hidden ? 5 : 0)
                    }
                    .frame(width: 64)
                }
            }
        }
    }
}

/// Останні операції з кружечками категорій.
struct MonoOperations: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                WidgetTitle(text: "Операції")
                Spacer()
                if model.monoLoading { ProgressView().controlSize(.mini) }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let left = model.monoCooldownLeft
                    IconButton(help: left > 0 ? "Оновити можна через \(left) с (обмеження монобанку)" : "Оновити") {
                        model.refreshMono(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold)).opacity(left > 0 ? 0.35 : 1)
                    }
                }
                IconButton(help: model.monoHidden ? "Показати суми" : "Приховати суми") {
                    model.monoHidden.toggle()
                } label: {
                    Image(systemName: model.monoHidden ? "eye.slash" : "eye").font(.system(size: 10, weight: .bold))
                }
            }
            if !model.rates.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.rates) { r in
                        HStack(spacing: 3) {
                            Text(Monobank.currencySymbol(r.currencyCodeA)).font(.system(size: 10.5, weight: .bold)).foregroundStyle(Palette.secondary)
                            Text(MonoCurrency.format(r.sell)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                        }
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Palette.surface))
                        .help("Курс монобанку: купівля \(MonoCurrency.format(r.rateBuy)) · продаж \(MonoCurrency.format(r.sell)) ₴")
                    }
                }
            }
            if let err = model.monoError {
                Text(err).font(.system(size: 11)).foregroundStyle(Palette.warning).lineLimit(2)
            }
            if model.monoStatement.isEmpty {
                Text("Операцій за 7 днів немає").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.monoStatement) { t in
                            HStack(spacing: 8) {
                                Text(t.icon).font(.system(size: 13))
                                    .frame(width: 26, height: 26)
                                    .background(Circle().fill(Palette.surface))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(t.description).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    Text(t.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                        .font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                                }
                                Spacer(minLength: 6)
                                Text(Monobank.formatMoney(t.amount, currency: t.currencyCode, showPlus: true))
                                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(t.amount > 0 ? Palette.positive : .white)
                                    .blur(radius: model.monoHidden ? 6 : 0)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Система: температура, навантаження, пам'ять, батарея

struct SystemView: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                WidgetTitle(text: "Процесор")
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(monitor.temps.cpu.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(.system(size: 46, weight: .bold).monospacedDigit())
                        .foregroundStyle(tempColor(monitor.temps.cpu))
                    Text("°C").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.secondary)
                }
                Text(monitor.temps.cpu.map { SensorSummary.feel($0) } ?? "датчик недоступний")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                Text("Охолодження: \(monitor.thermalText)")
                    .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                Text("Акумулятор \(monitor.temps.battery.map { "\(Int($0.rounded()))°" } ?? "—") · Диск \(monitor.temps.ssd.map { "\(Int($0.rounded()))°" } ?? "—")")
                    .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            }
            .frame(width: 180, alignment: .topLeading)

            WidgetDivider()

            HStack(spacing: 18) {
                Ring(title: "Навантаження", value: monitor.cpuLoad,
                     label: monitor.cpuLoad.map { "\(Int(($0 * 100).rounded()))%" } ?? "…")
                Ring(title: "Пам'ять", value: memoryFraction,
                     label: String(format: "%.1f ГБ", Double(monitor.memoryUsed) / 1_073_741_824),
                     caption: String(format: "з %.0f ГБ", Double(monitor.memoryTotal) / 1_073_741_824))
                Ring(title: monitor.charging ? "Заряджається" : (monitor.onAC ? "Від мережі" : "Батарея"),
                     value: monitor.batteryPercent.map { Double($0) / 100 },
                     label: monitor.batteryPercent.map { "\($0)%" } ?? "—",
                     tint: (monitor.batteryPercent ?? 100) <= 20 ? Palette.hot : Palette.positive)
            }
            .frame(maxWidth: .infinity)

            WidgetDivider()

            VStack(alignment: .leading, spacing: 5) {
                WidgetTitle(text: "Найбільше пам'яті")
                    .help("macOS сама звільняє пам'ять, коли треба. Закривай лише те, чим зараз не користуєшся — програма спитає, якщо щось не збережено.")
                if monitor.topMemory.isEmpty {
                    Text("Рахую…").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
                ForEach(monitor.topMemory) { e in
                    MemoryRow(entry: e) { MemoryTop.quit(e); monitor.update() }
                }
            }
            .frame(width: 236, alignment: .topLeading)
        }
        .onAppear { monitor.wantsTopMemory = true; monitor.update() }
        .onDisappear { monitor.wantsTopMemory = false }
    }

    private var memoryFraction: Double? {
        guard monitor.memoryTotal > 0 else { return nil }
        return Double(monitor.memoryUsed) / Double(monitor.memoryTotal)
    }

    private func tempColor(_ t: Double?) -> Color {
        guard let t else { return .white }
        return t >= 85 ? Palette.hot : t >= 70 ? Palette.warning : .white
    }
}

struct Ring: View {
    let title: String
    let value: Double?
    let label: String
    var caption: String? = nil
    var tint: Color = Palette.accent

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: value ?? 0)
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
                VStack(spacing: 0) {
                    Text(label).font(.system(size: 13, weight: .bold).monospacedDigit())
                    if let caption { Text(caption).font(.system(size: 9)).foregroundStyle(Palette.tertiary) }
                }
            }
            .frame(width: 72, height: 72)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary).lineLimit(1)
        }
    }
}

struct MemoryRow: View {
    let entry: MemoryTop.Entry
    let quit: () -> Void
    @State private var done = false

    var body: some View {
        HStack(spacing: 7) {
            if let id = entry.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
            }
            Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            Text(MemoryTop.gb(entry.bytes)).font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.secondary)
            Button {
                quit()
                withAnimation { done = true }
            } label: {
                Label(done ? "Закрито" : "Закрити", systemImage: done ? "checkmark" : "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(done ? Palette.positive.opacity(0.85) : Palette.surfaceHover))
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .disabled(done)
            .help("Звичайне «Вийти» для \(entry.name). Якщо там щось не збережено — програма спитає.")
        }
        .frame(height: 24)
    }
}

struct TempLine: View {
    let icon: String
    let title: String
    let value: Double?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Palette.secondary).frame(width: 18)
            Text(title).font(.system(size: 12.5))
            Spacer()
            Text(value.map { "\(Int($0.rounded()))°" } ?? "—").font(.system(size: 12.5, weight: .semibold).monospacedDigit())
        }
    }
}

// MARK: - Викачане: останні файли з «Завантажень»

struct DownloadsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: DownloadsStore

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Викачане").font(.system(size: 14, weight: .bold))
                Text("\(store.items.count) останніх файлів").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                Button { store.openFolder() } label: {
                    Label("Відкрити папку", systemImage: "folder").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Palette.secondary)
            }
            .frame(width: 196, alignment: .topLeading)

            WidgetDivider()

            if store.denied {
                VStack(spacing: 8) {
                    Text("Немає доступу до папки «Завантаження»").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.secondary)
                    PillButton(title: "Відкрити налаштування доступу", icon: "lock.open", prominent: true) { store.openPrivacySettings() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.items.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 20)).foregroundStyle(Palette.tertiary)
                    Text("У «Завантаженнях» поки порожньо").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.items) { item in
                                DownloadCard(item: item, now: context.date, store: store, model: model)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { store.startWatching() }
    }
}

struct DownloadCard: View {
    let item: DownloadsStore.Item
    let now: Date
    @ObservedObject var store: DownloadsStore
    @ObservedObject var model: AppModel
    @State private var hover = Debug.forceHover

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable().frame(width: 46, height: 46)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                if item.inProgress {
                    ProgressView().controlSize(.mini).offset(x: 4, y: 4)
                }
            }
            Text(item.name).font(.system(size: 11, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
            Text(meta).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(Palette.tertiary).lineLimit(1)
        }
        .padding(8)
        .frame(width: 128, height: 124)
        .opacity(hover ? 0 : 1)
        .overlay {
            if hover {
                VStack(spacing: 3) {
                    CardActionButton(title: "Відкрити", icon: "arrow.up.forward.square") { store.open(item) }
                    CardActionButton(title: "У Finder", icon: "folder") { store.reveal(item) }
                    let onShelf = model.shelf.contains { $0.url == item.url }
                    CardActionButton(title: onShelf ? "На полиці" : "На полицю", icon: "tray.and.arrow.down",
                                     persistentDone: onShelf) { model.addToShelf([item.url]) }
                    if ImageText.isImage(item.url) {
                        CardActionButton(title: "Текст з фото", icon: "text.viewfinder") { model.recognizeText(in: item.url) }
                    } else {
                        Text("або перетягни кудись").font(.system(size: 9.5)).foregroundStyle(Palette.tertiary)
                    }
                }
                .padding(8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(hover ? 0.2 : 0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(item.url.lastPathComponent)
    }

    private var meta: String {
        if item.inProgress { return "завантажується…" }
        let m = Int(now.timeIntervalSince(item.added) / 60)
        let ago: String
        if m < 1 { ago = "щойно" }
        else if m < 60 { ago = "\(m) хв тому" }
        else if m < 24 * 60 { ago = "\(m / 60) год тому" }
        else { ago = item.added.formatted(.dateTime.day().month(.abbreviated)) }
        let size = DownloadsStore.sizeText(item.size)
        return size.isEmpty ? ago : "\(ago) · \(size)"
    }
}

// MARK: - Мої нагадування: швидкий записник

struct RemindersView: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                NotesModeSwitch(model: model)
                Text("\(model.openReminders) \(model.openReminders == 1 ? "відкрите" : "відкритих")")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.secondary)
                HStack(spacing: 6) {
                    TextField("Нове нагадування…", text: $model.newReminder)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .focusEffectDisabled()
                        .onSubmit { model.addReminder(); focused = true }
                    Button { model.addReminder(); focused = true } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(model.newReminder.trimmingCharacters(in: .whitespaces).isEmpty
                                                      ? Color.white.opacity(0.12) : Palette.accent))
                    }
                    .buttonStyle(.plain)
                    .help("Додати (Enter)")
                }
                .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
                .background(Capsule().fill(Palette.surface))
                .overlay(Capsule().strokeBorder(focused ? Palette.accent.opacity(0.6) : .clear))
                if model.reminders.contains(where: \.isDone) {
                    Button { model.clearDoneReminders() } label: {
                        Label("Прибрати виконані", systemImage: "checkmark.circle").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.secondary)
                }
            }
            .frame(width: 210, alignment: .topLeading)

            WidgetDivider()

            if model.reminders.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checklist").font(.system(size: 20)).foregroundStyle(Palette.tertiary)
                    Text("Запиши, що не хочеш забути").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.secondary)
                    Text("Enter — додати · кружечок — виконано").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                        ForEach(model.reminders) { note in
                            ReminderRow(note: note,
                                        toggle: { model.toggleReminder(note) },
                                        delete: { model.deleteReminder(note) })
                        }
                    }
                }
            }
        }
        .onAppear {
            model.refreshReminders()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }
}

/// Перемикач «Нагадування | Шаблони» у вкладці «Мої нагадування».
struct NotesModeSwitch: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach([(0, "Нагадування", "checklist"), (1, "Шаблони", "text.quote")], id: \.0) { mode, title, icon in
                Button { withAnimation(Palette.spring) { model.notesMode = mode } } label: {
                    Label(title, systemImage: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(model.notesMode == mode ? Palette.pill : .clear))
                        .foregroundStyle(model.notesMode == mode ? .white : Palette.secondary)
                        .contentShape(Capsule())
                        .fixedSize()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Palette.surface))
    }
}

/// Шаблони повідомлень: заготовки, адреса доставки, реквізити — клік копіює.
struct TemplatesView: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                NotesModeSwitch(model: model)
                Text("Клік по шаблону — скопіювати").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.secondary)
                HStack(alignment: .bottom, spacing: 6) {
                    TextField("Новий шаблон…", text: $model.newTemplate, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .lineLimit(1...2)
                        .focused($focused)
                        .focusEffectDisabled()
                        .onSubmit { model.addTemplate(); focused = true }
                    Button { model.addTemplate(); focused = true } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(model.newTemplate.trimmingCharacters(in: .whitespaces).isEmpty
                                                      ? Color.white.opacity(0.12) : Palette.accent))
                    }
                    .buttonStyle(.plain)
                    .help("Зберегти шаблон (Enter; ⌥Enter — новий рядок)")
                }
                .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(focused ? Palette.accent.opacity(0.6) : .clear))
            }
            .frame(width: 210, alignment: .topLeading)

            WidgetDivider()

            if model.templates.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.quote").font(.system(size: 20)).foregroundStyle(Palette.tertiary)
                    Text("Збережи текст, який часто пишеш").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.secondary)
                    Text("адреса доставки, реквізити, «буду за 10 хв»").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                        ForEach(model.templates) { t in
                            TemplateRow(template: t, copied: model.copiedTemplateID == t.id,
                                        copy: { model.copyTemplate(t) }, delete: { model.deleteTemplate(t) })
                        }
                    }
                }
            }
        }
        .onAppear {
            model.refreshTemplates()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }
}

struct TemplateRow: View {
    let template: Template
    let copied: Bool
    let copy: () -> Void
    let delete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(copied ? Palette.positive : Palette.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(copied ? "Скопійовано" : template.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(copied ? Palette.positive : .white)
                if template.text.contains("\n") {
                    Text(template.text.split(separator: "\n").dropFirst().joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(Palette.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if hover {
                Button(action: delete) {
                    Image(systemName: "trash").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary)
                }
                .buttonStyle(.plain)
                .help("Видалити шаблон")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(copied ? Palette.positive.opacity(0.18) : (hover ? Palette.surfaceHover : Palette.surface)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(copied ? Palette.positive.opacity(0.7) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: copy)
        .onHover { hover = $0 }
        .help(template.text)
    }
}

struct ReminderRow: View {
    let note: ReminderNote
    let toggle: () -> Void
    let delete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: note.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(note.isDone ? Palette.positive : Palette.secondary)
            }
            .buttonStyle(.plain)
            .help(note.isDone ? "Повернути у відкриті" : "Позначити виконаним")
            VStack(alignment: .leading, spacing: 1) {
                Text(note.text)
                    .font(.system(size: 12.5, weight: .medium))
                    .strikethrough(note.isDone, color: Palette.tertiary)
                    .foregroundStyle(note.isDone ? Palette.tertiary : .white)
                    .lineLimit(2)
                Text(note.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                    .font(.system(size: 9.5)).foregroundStyle(Palette.tertiary)
            }
            Spacer(minLength: 4)
            if hover {
                Button(action: delete) {
                    Image(systemName: "trash").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary)
                }
                .buttonStyle(.plain)
                .help("Видалити")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12).fill(hover ? Palette.surfaceHover : Palette.surface))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(note.text)
    }
}

// MARK: - Календар: смужка тижня, і події дня

struct CalendarView: View {
    @ObservedObject var store: CalendarStore

    var body: some View {
        switch store.access {
        case .granted: content
        case .notDetermined:
            permission(text: "Notch Menu може показувати найближчі події з «Календаря» Mac (лише читання).",
                       button: "Дозволити доступ до Календаря") { store.requestAccess() }
        case .denied:
            permission(text: "Доступ до Календаря вимкнено. Увімкни Notch Menu у Системних параметрах → Конфіденційність → Календарі.",
                       button: "Відкрити налаштування") { store.openPrivacySettings() }
        }
    }

    private func permission(text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar").font(.system(size: 22)).foregroundStyle(Palette.secondary)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
            PillButton(title: button, icon: "lock.open", prominent: true, action: action)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(store.selectedDay.formatted(.dateTime.month(.abbreviated)).capitalized)
                        .font(.system(size: 26, weight: .bold))
                    Text(store.selectedDay.formatted(.dateTime.weekday(.wide)).capitalized)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                }
                HStack(spacing: 4) {
                    ForEach(store.week, id: \.self) { day in dayCell(day) }
                }
            }
            .frame(width: 330, alignment: .topLeading)

            WidgetDivider()

            let list = store.events(on: store.selectedDay)
            if list.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "calendar.badge.checkmark").font(.system(size: 18)).foregroundStyle(Palette.tertiary)
                    Text(Calendar.current.isDateInToday(store.selectedDay) ? "На сьогодні нічого" : "Цього дня вільно")
                        .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(list, id: \.eventIdentifier) { e in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(nsColor: e.calendar?.color ?? .systemBlue))
                                    .frame(width: 4, height: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.title ?? "Без назви").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(timeText(e)).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface.opacity(0.6)))
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let selected = Calendar.current.isDate(day, inSameDayAs: store.selectedDay)
        let today = Calendar.current.isDateInToday(day)
        let hasEvents = !store.events(on: day).isEmpty
        return Button { store.selectedDay = day } label: {
            VStack(spacing: 2) {
                Text(day.formatted(.dateTime.weekday(.narrow)).uppercased())
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.tertiary)
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: selected ? 20 : 16, weight: .bold).monospacedDigit())
                    .foregroundStyle(selected ? Color.accentColor : (today ? .white : Palette.secondary))
                Circle().fill(hasEvents ? Palette.accent : .clear).frame(width: 4, height: 4)
            }
            .frame(width: 40, height: 52)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Palette.surface : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func timeText(_ e: EKEvent) -> String {
        if e.isAllDay { return "Увесь день" }
        let t = "\(e.startDate.formatted(date: .omitted, time: .shortened)) – \(e.endDate.formatted(date: .omitted, time: .shortened))"
        if let loc = e.location, !loc.isEmpty { return "\(t) · \(loc)" }
        return t
    }
}

// MARK: - Налаштування (сітка 2 × 3)

/// Налаштування: розділи-«пігулки» зверху, під ними — лише налаштування вибраного розділу з поясненнями.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("settingsSection") private var section = "general"

    private let sections: [(id: String, title: String, icon: String)] = [
        ("general", "Загальне", "gearshape"), ("music", "Музика", "music.note"), ("claude", "ШІ", "sparkles"),
        ("mono", "Моно", "creditcard"), ("access", "Дозволи", "lock.shield"), ("keys", "Клавіші", "keyboard"),
        ("about", "Про програму", "info.circle"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(sections, id: \.id) { item in
                    Button { withAnimation(.easeOut(duration: 0.15)) { section = item.id } } label: {
                        Label(item.title, systemImage: item.icon)
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(section == item.id ? Palette.pill : .clear))
                            .foregroundStyle(section == item.id ? .white : Palette.secondary)
                            .contentShape(Capsule())
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 8) {
                rows
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var rows: some View {
        switch section {
        case "music":
            SettingItem(icon: "music.note.list", title: "Джерело музики", subtitle: "Що показувати в «Зараз грає»") {
                Picker("", selection: Binding(get: { model.nowPlaying.source }, set: { model.nowPlaying.source = $0 })) {
                    ForEach(MusicSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            }
            SettingItem(icon: "phone.down", title: "Пауза під час дзвінка", subtitle: "Telegram, Viber, WhatsApp, FaceTime зайняли мікрофон — пауза") {
                Toggle("", isOn: $model.pauseOnCall).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            SettingItem(icon: "hand.raised", title: "Керування «Музикою» й Chrome", subtitle: "Якщо macOS заборонила — увімкни тут") {
                Button("Відкрити") { model.nowPlaying.openPrivacySettings() }.controlSize(.small)
            }
        case "claude":
            SettingItem(icon: "sparkles", title: model.claudeViaSubscription ? "Через підписку Claude" : "Через ключ API",
                        subtitle: "Увімкни, щоб питати Opus і Fable через ключ API") {
                Toggle("", isOn: $model.useAPIKey).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            SettingItem(icon: "key.fill", title: "Ключ Claude API", subtitle: model.hasSecret(.anthropic) ? "Збережено в «Зв'язці ключів»" : "Не додано (для підписки не потрібен)") {
                Button(model.hasSecret(.anthropic) ? "Змінити" : "Додати") { model.editSecret(.anthropic) }.controlSize(.small)
            }
            SettingItem(icon: "diamond", title: "Ключ Gemini (безкоштовно)",
                        subtitle: model.hasGeminiKey ? "Збережено в «Зв'язці ключів»"
                            : model.geminiCLIAvailable ? "Не потрібен: є Gemini CLI" : "Не додано · aistudio.google.com") {
                Button(model.hasGeminiKey ? "Змінити" : "Додати") { model.editSecret(.gemini) }.controlSize(.small)
            }
            if model.geminiCLIAvailable && model.hasGeminiKey {
                SettingItem(icon: "terminal", title: model.geminiViaKey ? "Gemini через ключ" : "Gemini через CLI",
                            subtitle: "Увімкни, щоб Gemini йшов через ключ, а не CLI") {
                    Toggle("", isOn: $model.geminiViaKey).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
        case "mono":
            SettingItem(icon: "key.fill", title: "Токен монобанку", subtitle: model.hasMonoToken ? "Збережено в «Зв'язці ключів» · лише перегляд" : "Не додано") {
                Button(model.hasMonoToken ? "Змінити" : "Додати") { model.editSecret(.monobank) }.controlSize(.small)
            }
            SettingItem(icon: "chart.pie", title: "Бюджет на місяць", subtitle: "На картці буде «сьогодні ще … ₴». 0 — вимкнено") {
                HStack(spacing: 3) {
                    TextField("0", value: $model.monoBudget, format: .number)
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("₴").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
            SettingItem(icon: "eye.slash", title: "Приховувати суми", subtitle: "Розмиває баланс і операції в «Моно»") {
                Toggle("", isOn: $model.monoHidden).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
        case "access":
            SettingItem(icon: "bell.badge", title: "Універсальний доступ", subtitle: "Лічильники, кнопки YouTube Music, ⌃⌥L") {
                if model.badgesTrusted {
                    Label("Є", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.positive)
                } else {
                    Button("Дозволити") { model.requestBadgePermission() }.controlSize(.small)
                }
            }
            SettingItem(icon: "calendar", title: "Календар", subtitle: "Найближча подія й тиждень (лише читання)") {
                switch model.calendar.access {
                case .granted:
                    Label("Є", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.positive)
                case .notDetermined:
                    Button("Дозволити") { model.calendar.requestAccess() }.controlSize(.small)
                case .denied:
                    Button("Відкрити") { model.calendar.openPrivacySettings() }.controlSize(.small)
                }
            }
            SettingItem(icon: "lock.shield", title: "Буфер без паролів", subtitle: "Текст лише в пам'яті 60 хв; паролі й ключі не зберігаються") {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(Palette.positive)
            }
            SettingItem(icon: "arrow.down.circle", title: "Папка «Завантаження»", subtitle: model.downloads.denied ? "Немає доступу" : "Для вкладки «Викачане»") {
                if model.downloads.denied {
                    Button("Відкрити") { model.downloads.openPrivacySettings() }.controlSize(.small)
                } else {
                    Label("Є", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.positive)
                }
            }
        case "keys":
            ForEach(ShortcutAction.allCases) { action in
                SettingItem(icon: action == .panel ? "rectangle.topthird.inset.filled" : "character.cursor.ibeam",
                            title: action.title, subtitle: model.shortcutConflicts.contains(action) ? "Зайнята іншою програмою" : action.help) {
                    HStack(spacing: 6) {
                        Text(model.shortcut(action).label).font(.system(size: 12, weight: .bold).monospaced())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surfaceHover))
                        Button("Змінити") { model.select(.shortcuts); model.startRecording(action) }.controlSize(.small)
                    }
                }
            }
            SettingItem(icon: "list.bullet", title: "Усі комбінації", subtitle: "Esc, ↩, ⌥↩ і запис нових") {
                Button("Показати") { model.select(.shortcuts) }.controlSize(.small)
            }
        case "about":
            SettingItem(icon: "app.badge", title: "Notch Menu \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")",
                        subtitle: "Безкоштовна програма з відкритим кодом") {
                EmptyView()
            }
            SettingItem(icon: "cup.and.saucer.fill", title: "Підтримати автора", subtitle: "Банка монобанку: будь-які картки, Apple Pay, Google Pay") {
                DonateButton()
            }
            SettingItem(icon: "power", title: "Вийти з програми", subtitle: "Автозапуск відкриє її знову після входу") {
                Button("Вийти") { NSApp.terminate(nil) }.controlSize(.small)
            }
        default:  // «Загальне»
            SettingItem(icon: "power", title: "Запускати при вході", subtitle: model.launchNeedsApproval ? "Підтверди в «Елементах входу»" : "Notch Menu стартує сам") {
                HStack(spacing: 6) {
                    if model.launchNeedsApproval {
                        Button("Підтвердити") { model.openLoginItemsSettings() }.controlSize(.small)
                    }
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
            SettingItem(icon: "eye", title: "Що показувати", subtitle: model.hiddenSections.isEmpty ? "Сховати непотрібні вкладки й віджети" : "Сховано: \(model.hiddenSections.count)") {
                Button("Вибрати") { model.select(.visibility) }.controlSize(.small)
            }
            SettingItem(icon: "keyboard", title: "Відкрити панель", subtitle: "Навести на чубчик або \(model.shortcut(.panel).label)") {
                EmptyView()
            }
            SettingItem(icon: "cup.and.saucer.fill", title: "Підтримати автора", subtitle: "Якщо програма тобі корисна") {
                DonateButton()
            }
        }
    }
}

/// Рядок налаштування: значок · назва й пояснення · керування праворуч.
struct SettingItem<Control: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.surface))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            control()
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface.opacity(0.6)))
        .help(subtitle)
    }
}

/// «Комбінації клавіш»: усі комбінації програми; дві головні можна змінити.
struct ShortcutsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Button { model.stopRecording(); model.select(.settings) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Palette.surface))
                }
                .buttonStyle(.plain)
                .help("Назад до налаштувань")
                Text("Комбінації клавіш").font(.system(size: 13, weight: .bold))
                Spacer()
                Text(model.shortcutNote ?? "«Змінити» → натисни потрібні клавіші")
                    .font(.system(size: 11, weight: model.shortcutNote == nil ? .regular : .semibold))
                    .foregroundStyle(model.shortcutNote?.hasPrefix("Готово") == true ? Palette.positive
                                     : model.shortcutNote == nil ? Palette.tertiary : Palette.warning)
                    .lineLimit(1)
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 6) {
                    ForEach(ShortcutAction.allCases) { action in editableRow(action) }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    WidgetTitle(text: "У самій панелі")
                    infoRow("Esc", "закрити панель")
                    infoRow("↩", "надіслати / додати / скопіювати результат")
                    infoRow("⌥↩", "новий рядок у полі")
                    infoRow("⌘V", "вставити")
                }
                .frame(width: 250, alignment: .topLeading)
            }
        }
        .onDisappear { model.stopRecording() }
    }

    private func editableRow(_ action: ShortcutAction) -> some View {
        let recording = model.recordingShortcut == action
        let conflict = model.shortcutConflicts.contains(action)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(action.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(conflict ? "зайнята іншою програмою — вибери іншу" : action.help)
                    .font(.system(size: 9.5)).foregroundStyle(conflict ? Palette.warning : Palette.tertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(recording ? "натисни…" : model.shortcut(action).label)
                .font(.system(size: 13, weight: .bold).monospaced())
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 7).fill(recording ? Palette.accent.opacity(0.35) : Palette.surfaceHover))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(conflict ? Palette.warning : .clear))
            Button(recording ? "Скасувати" : "Змінити") {
                recording ? model.stopRecording() : model.startRecording(action)
            }
            .controlSize(.small)
            if model.shortcut(action) != action.defaultShortcut {
                Button { model.resetShortcut(action) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain).foregroundStyle(Palette.secondary)
                    .help("Повернути \(action.defaultShortcut.label)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface.opacity(0.6)))
    }

    private func infoRow(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(keys).font(.system(size: 11, weight: .bold).monospaced())
                .frame(width: 34, alignment: .leading)
            Text(text).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
        }
    }
}

/// «Що показувати»: перемикачі для кожної вкладки й віджета.
struct VisibilityView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { model.select(.settings) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Palette.surface))
                }
                .buttonStyle(.plain)
                .help("Назад до налаштувань")
                Text("Що показувати в панелі").font(.system(size: 13, weight: .bold))
                Spacer()
                Text("Головна й налаштування видно завжди").font(.system(size: 10.5)).foregroundStyle(Palette.tertiary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 6) {
                ForEach(AppModel.Section.allCases) { section in
                    HStack(spacing: 8) {
                        Image(systemName: section.icon).font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Palette.surface))
                            .opacity(model.isShown(section) ? 1 : 0.4)
                        Text(section.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(model.isShown(section) ? .white : Palette.tertiary)
                        Spacer(minLength: 4)
                        Toggle("", isOn: Binding(get: { model.isShown(section) }, set: { model.setShown(section, $0) }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface.opacity(0.6)))
                }
            }
        }
    }
}

/// Маленька кнопка «☕ Донат» → банка монобанку автора. Після кліку — зелене «Дякую!».
struct DonateButton: View {
    static let url = URL(string: "https://send.monobank.ua/jar/9rEAGpeFqv")!
    @State private var thanked = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(Self.url)
            withAnimation { thanked = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { thanked = false } }
        } label: {
            Label(thanked ? "Дякую!" : "Донат", systemImage: thanked ? "heart.fill" : "cup.and.saucer.fill")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(thanked ? Palette.positive.opacity(0.85) : Palette.accent.opacity(0.85)))
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

struct SettingTile<Control: View>: View {
    let icon: String
    let title: String
    let help: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Palette.surface))
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 6)
            control()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface.opacity(0.6)))
        .help(help)
    }
}
