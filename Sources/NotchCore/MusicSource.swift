import Foundation

/// Звідки показувати «Зараз грає».
public enum MusicSource: String, CaseIterable, Identifiable, Sendable {
    case appleMusic, youtubeMusic

    public var id: String { rawValue }
    public var title: String { self == .appleMusic ? "Apple Music" : "YouTube Music" }
}

public enum YouTubeMusicTitle {
    /// Заголовок вікна Chrome: «Falling (feat. X) | YouTube Music – відтворюється аудіо - Google Chrome – Профіль».
    public static func parseWindow(_ raw: String) -> (title: String, artist: String?, playing: Bool)? {
        var t = raw
        if let r = t.range(of: " - Google Chrome") { t = String(t[..<r.lowerBound]) }
        let markers = [" – відтворюється аудіо", " - відтворюється аудіо", " – Playing audio", " - Playing audio",
                       " – Audio playing", " - Audio playing", " – воспроизводится аудио"]
        var playing = false
        for m in markers where t.contains(m) {
            playing = true
            t = t.replacingOccurrences(of: m, with: "")
        }
        guard t.contains("YouTube Music"), let parsed = parse(t) else { return nil }
        return (parsed.title, parsed.artist, playing)
    }

    /// Заголовок вкладки music.youtube.com → (назва, виконавець).
    /// Приклади: «Dibi Dibi Rek • Ismaël Lô - YouTube Music», «Dibi Dibi Rek - YouTube Music», «YouTube Music».
    public static func parse(_ raw: String) -> (title: String, artist: String?)? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - YouTube Music", " – YouTube Music", " | YouTube Music"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != "YouTube Music" else { return nil }
        for sep in [" • ", " · "] {
            let parts = t.components(separatedBy: sep)
            if parts.count >= 2 {
                return (parts[0], parts[1...].joined(separator: sep))
            }
        }
        return (t, nil)
    }
}
