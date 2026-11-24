import Foundation
import SwiftUI

// MARK: - Lyrics (vom Hub, einmal geladen → offline)

@MainActor
final class Lyrics: ObservableObject {
    static let shared = Lyrics()
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plain: String?
    @Published private(set) var loadingFor: String?
    private(set) var trackID: String?
    /// neuer Ordner: alte Einträge „keine Lyrics“ (vor der verbesserten Suche) werden neu geholt
    private let dir = Store.dir("Lyrics2")

    private func cached(_ id: String) -> LyricsResponse? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(id).json")) else { return nil }
        return try? JSONDecoder().decode(LyricsResponse.self, from: d)
    }
    /// Ergebnis ohne getimte Zeilen nur einen Tag merken – vielleicht hat der PC inzwischen welche (Whisper-Timing)
    private func isFresh(_ id: String) -> Bool {
        guard let r = cached(id) else { return false }
        if !(r.lines ?? []).isEmpty { return true }
        let f = dir.appendingPathComponent("\(id).json")
        let age = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) } ?? .infinity
        return age < 86400
    }

    func load(_ t: Track?) async {
        guard let t else { lines = []; plain = nil; trackID = nil; return }
        if trackID == t.id && !lines.isEmpty { return }
        trackID = t.id
        if let r = cached(t.id) { lines = r.lines ?? []; plain = r.plain } else { lines = []; plain = nil }
        if isFresh(t.id) { return }
        loadingFor = t.id
        defer { if loadingFor == t.id { loadingFor = nil } }
        guard let r = try? await API.get("/api/lyrics/\(t.id)", timeout: 25, as: LyricsResponse.self), r.error == nil else { return }
        if let d = try? JSONEncoder().encode(r) { try? d.write(to: dir.appendingPathComponent("\(t.id).json")) }
        if trackID == t.id { lines = r.lines ?? []; plain = r.plain }
    }

    /// nur Vorführmodus
    func demo(_ id: String, _ l: [LyricLine]) { trackID = id; lines = l }

    /// Songs sind im Hub-Tempo gerendert → Lyrics-Zeit = Wiedergabezeit × Tempo
    func index(at seconds: Double, rate: Double) -> Int? {
        let ms = seconds * 1000 * rate
        var hit: Int?
        for (i, l) in lines.enumerated() where l.ms <= ms + 150 { hit = i }
        return hit
    }

    /// Lyrics für alle Songs vorab holen (solange der PC da ist), damit sie unterwegs da sind.
    /// Ein Song ohne Lyrics bricht nicht mehr alles ab (vorher hörte es beim ersten Fehlschlag auf).
    func prefetch(_ tracks: [Track]) async {
        var fails = 0
        for t in tracks where !isFresh(t.id) {
            guard let r = try? await API.get("/api/lyrics/\(t.id)", timeout: 25, as: LyricsResponse.self) else {
                fails += 1
                if fails >= 3 { return }       // PC weg → später weitermachen
                continue
            }
            fails = 0
            if r.error == nil, let d = try? JSONEncoder().encode(r) { try? d.write(to: dir.appendingPathComponent("\(t.id).json")) }
            if trackID == t.id, r.error == nil { lines = r.lines ?? []; plain = r.plain }
        }
    }
}
