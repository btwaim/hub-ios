import Foundation
import SwiftUI
import AlarmKit
import ActivityKit

// MARK: - Lyrics (vom Hub, einmal geladen → offline)

@MainActor
final class Lyrics: ObservableObject {
    static let shared = Lyrics()
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plain: String?
    @Published private(set) var loadingFor: String?
    private(set) var trackID: String?
    private let dir = Store.dir("Lyrics")

    func load(_ t: Track?) async {
        guard let t else { lines = []; plain = nil; trackID = nil; return }
        if trackID == t.id { return }
        trackID = t.id
        lines = []; plain = nil
        let file = dir.appendingPathComponent("\(t.id).json")
        if let d = try? Data(contentsOf: file), let r = try? JSONDecoder().decode(LyricsResponse.self, from: d) {
            lines = r.lines ?? []; plain = r.plain
            return
        }
        loadingFor = t.id
        defer { if loadingFor == t.id { loadingFor = nil } }
        guard let r = try? await API.get("/api/lyrics/\(t.id)", timeout: 20, as: LyricsResponse.self), r.error == nil else { return }
        if let d = try? JSONEncoder().encode(r) { try? d.write(to: file) }
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

    /// Lyrics für alle Songs vorab holen (solange der PC da ist), damit sie unterwegs da sind
    func prefetch(_ tracks: [Track]) async {
        for t in tracks {
            let file = dir.appendingPathComponent("\(t.id).json")
            if FileManager.default.fileExists(atPath: file.path) { continue }
            guard let r = try? await API.get("/api/lyrics/\(t.id)", timeout: 20, as: LyricsResponse.self), r.error == nil else { return }
            if let d = try? JSONEncoder().encode(r) { try? d.write(to: file) }
        }
    }
}

// MARK: - Wecker nach Stundenplan (echte iPhone-Wecker über AlarmKit, klingeln auch ohne PC)

