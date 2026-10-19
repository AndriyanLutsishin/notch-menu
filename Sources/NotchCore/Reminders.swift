import Foundation

/// «Мої нагадування» — швидкий записник. Зберігається у файлі програми на цьому Mac
/// (~/Library/Application Support/NotchMenu/reminders.json), нікуди не надсилається.
public struct ReminderNote: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public let createdAt: Date
    public var doneAt: Date?

    public var isDone: Bool { doneAt != nil }

    public init(id: UUID = UUID(), text: String, createdAt: Date, doneAt: Date? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.doneAt = doneAt
    }
}

public final class ReminderStore {
    public private(set) var notes: [ReminderNote] = []
    private let fileURL: URL
    private let now: () -> Date

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NotchMenu", isDirectory: true).appendingPathComponent("reminders.json")
    }

    public init(fileURL: URL = ReminderStore.defaultURL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        load()
    }

    /// Відкриті — зверху (новіші перші), виконані — внизу (щойно закриті перші).
    public var sorted: [ReminderNote] {
        let open = notes.filter { !$0.isDone }.sorted { $0.createdAt > $1.createdAt }
        let done = notes.filter(\.isDone).sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
        return open + done
    }

    public var openCount: Int { notes.filter { !$0.isDone }.count }

    @discardableResult
    public func add(_ raw: String) -> ReminderNote? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let note = ReminderNote(text: String(text.prefix(500)), createdAt: now())
        notes.append(note)
        save()
        return note
    }

    public func toggle(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].doneAt = notes[i].isDone ? nil : now()
        save()
    }

    public func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    public func clearDone() {
        notes.removeAll(where: \.isDone)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([ReminderNote].self, from: data) { notes = decoded }
        else { SafeFile.backUpUnreadable(fileURL) }  // не затираємо файл, який не змогли прочитати
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(notes) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
