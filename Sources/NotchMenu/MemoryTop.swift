import AppKit
import Darwin

/// Які програми займають найбільше пам'яті (разом з їхніми допоміжними процесами, як у Chrome).
/// Лише читання; закриття — звичайне «Вийти», тож програма сама спитає, якщо щось не збережено.
enum MemoryTop {
    struct Entry: Identifiable, Equatable {
        let pid: pid_t
        let name: String
        let bundleID: String?
        let bytes: UInt64
        var id: pid_t { pid }
    }

    static func top(limit: Int = 3) -> [Entry] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && $0.bundleIdentifier != "com.apple.finder"
        }
        var appByPid: [pid_t: NSRunningApplication] = [:]
        for a in apps { appByPid[a.processIdentifier] = a }

        // Усі процеси користувача: батько й обсяг пам'яті.
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        var parent: [pid_t: pid_t] = [:]
        var footprint: [pid_t: UInt64] = [:]
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
                parent[pid] = pid_t(info.pbi_ppid)
            }
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            if ok == 0 { footprint[pid] = usage.ri_phys_footprint }
        }

        // Пам'ять допоміжних процесів додаємо до програми, яка за них «відповідає»
        // (так рахує й Монітор активності; Safari/Mail запускають помічників через систему, не напряму).
        var total: [pid_t: UInt64] = [:]
        for (pid, bytes) in footprint {
            var owner: pid_t? = nil
            if let r = responsible(pid), appByPid[r] != nil { owner = r }
            if owner == nil {
                var cur = pid
                var hops = 0
                while hops < 8, appByPid[cur] == nil, let p = parent[cur], p > 1 { cur = p; hops += 1 }
                if appByPid[cur] != nil { owner = cur }
            }
            if let owner { total[owner, default: 0] += bytes }
        }
        return total.compactMap { pid, bytes in
            guard let app = appByPid[pid] else { return nil }
            return Entry(pid: pid, name: app.localizedName ?? "Програма", bundleID: app.bundleIdentifier, bytes: bytes)
        }
        .sorted { $0.bytes > $1.bytes }
        .prefix(limit)
        .map { $0 }
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    private static func responsible(_ pid: pid_t) -> pid_t? {
        guard let fn = responsibleFn else { return nil }
        let r = fn(pid)
        return r > 0 ? r : nil
    }

    /// Звичайне «Вийти» (як ⌘Q): програма може спитати про збереження.
    @discardableResult
    static func quit(_ entry: Entry) -> Bool {
        NSRunningApplication(processIdentifier: entry.pid)?.terminate() ?? false
    }

    static func gb(_ bytes: UInt64) -> String {
        let g = Double(bytes) / 1_073_741_824
        return g >= 1 ? String(format: "%.1f ГБ", g).replacingOccurrences(of: ".", with: ",")
                      : String(format: "%.0f МБ", Double(bytes) / 1_048_576)
    }
}
