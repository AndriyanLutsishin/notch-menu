import AppKit

/// Останні файли з папки «Завантаження» (лише перегляд; macOS один раз питає дозвіл на цю папку).
@MainActor
final class DownloadsStore: ObservableObject {
    struct Item: Identifiable, Equatable {
        let url: URL
        let added: Date
        let size: Int64?
        let inProgress: Bool
        var id: URL { url }
        var name: String { inProgress ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var denied = false

    let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private var timer: Timer?

    /// Поки вкладка відкрита — оновлюємо кожні 3 с (щоб бачити, як докачується файл).
    func startWatching() {
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func reload() {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey, .fileSizeKey, .isHiddenKey]
        let folder = self.folder
        Task.detached(priority: .utility) {
            do {
                let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles])
                let partial = ["crdownload", "download", "part", "partial"]
                var list: [Item] = urls.compactMap { url in
                    let v = try? url.resourceValues(forKeys: Set(keys))
                    if v?.isHidden == true { return nil }
                    let date = v?.addedToDirectoryDate ?? v?.contentModificationDate ?? .distantPast
                    return Item(url: url, added: date, size: v?.fileSize.map(Int64.init),
                                inProgress: partial.contains(url.pathExtension.lowercased()))
                }
                list.sort { $0.added > $1.added }
                let top = Array(list.prefix(30))
                await MainActor.run {
                    self.denied = false
                    if top != self.items { self.items = top }
                }
            } catch {
                await MainActor.run { self.denied = true; self.items = [] }
            }
        }
    }

    func open(_ item: Item) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: Item) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    func openFolder() { NSWorkspace.shared.open(folder) }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }

    static func sizeText(_ bytes: Int64?) -> String {
        guard let bytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
