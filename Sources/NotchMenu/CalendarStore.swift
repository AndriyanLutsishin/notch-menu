import AppKit
import EventKit

/// Події з «Календаря» Mac на найближчі 7 днів. Лише читання; дозвіл macOS питає при першому кліку.
@MainActor
final class CalendarStore: ObservableObject {
    enum Access { case notDetermined, granted, denied }

    @Published private(set) var access: Access
    @Published private(set) var events: [EKEvent] = []
    @Published var selectedDay = Calendar.current.startOfDay(for: Date())

    private let store = EKEventStore()

    init() {
        access = Self.currentAccess()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAccess() {
        Task {
            let ok = (try? await store.requestFullAccessToEvents()) ?? false
            access = ok ? .granted : .denied
            reload()
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    func reload() {
        access = Self.currentAccess()
        guard access == .granted else { events = []; return }
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    /// Найближча подія сьогодні, яка ще не закінчилась.
    var nextEventToday: EKEvent? {
        let now = Date()
        return events.first { !$0.isAllDay && $0.endDate > now && Calendar.current.isDateInToday($0.startDate) }
    }

    func events(on day: Date) -> [EKEvent] {
        events.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) || ($0.isAllDay && $0.startDate <= day && $0.endDate > day) }
    }

    var week: [Date] {
        let start = Calendar.current.startOfDay(for: Date())
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }
}
