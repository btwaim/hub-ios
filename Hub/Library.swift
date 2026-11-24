import Foundation
import UIKit

/// Playlist + Offline-Speicher. Songs kommen vom Hub schon im Hub-Sound (Bass/Tempo/Hall eingerechnet).
@MainActor
final class Library: ObservableObject {
    struct Progress: Equatable { var done: Int; var total: Int; var title: String }

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var offline: Set<String> = []
    @Published private(set) var pcOnline = false
    @Published private(set) var syncing = false
    @Published private(set) var progress: Progress?
    @Published private(set) var lastError: String?

    private let songs = Store.dir("Songs")

    init() {
        tracks = Store.load([Track].self, "playlist.json") ?? []
        scan()
    }

    var offlineCount: Int { tracks.filter { offline.contains($0.fileName) }.count }
    var storageMB: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: songs, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return bytes / 1_000_000
    }

    func isOffline(_ t: Track) -> Bool { offline.contains(t.fileName) }
    func localURL(_ t: Track) -> URL? { isOffline(t) ? songs.appendingPathComponent(t.fileName) : nil }
    func streamURL(_ t: Track) -> URL? { Config.url("/hsong/\(t.id)", ["k": t.key ?? "1|0|0"]) }

    private func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: songs.path)) ?? []
        offline = Set(names.filter { $0.hasSuffix(".m4a") })
    }

    /// Playlist vom PC holen (falls erreichbar) und fehlende Songs herunterladen
    func refresh() async {
        guard Config.isSetUp else { return }
        do {
            let p = try await API.get("/api/playlist", timeout: 5, as: PlaylistResponse.self)
            if let t = p.tracks, !t.isEmpty {
                tracks = t
                Store.save(t, "playlist.json")
                pcOnline = true
                lastError = nil
            } else {
                pcOnline = false
                lastError = p.error
            }
        } catch {
            pcOnline = false
        }
        if pcOnline { await sync() }
    }

    func sync() async {
        guard pcOnline, !syncing else { return }
        syncing = true
        // etwas Zeit erbitten, falls die App währenddessen in den Hintergrund geht
        let bg = UIApplication.shared.beginBackgroundTask(withName: "songs")
        defer {
            syncing = false
            progress = nil
            UIApplication.shared.endBackgroundTask(bg)
        }
        // alte Versionen (Effekt im Hub geändert) und entfernte Songs löschen
        let wanted = Set(tracks.map(\.fileName))
        for name in offline where !wanted.contains(name) {
            try? FileManager.default.removeItem(at: songs.appendingPathComponent(name))
        }
        scan()
        let todo = tracks.filter { !isOffline($0) }
        var done = tracks.count - todo.count
        for t in todo {
            progress = Progress(done: done, total: tracks.count, title: t.title)
            guard let url = streamURL(t) else { break }
            var req = URLRequest(url: url)
            req.timeoutInterval = 300
            do {
                let (tmp, resp) = try await API.session.download(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let dest = songs.appendingPathComponent(t.fileName)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                offline.insert(t.fileName)
                done += 1
            } catch {
                pcOnline = false   // PC weg → beim nächsten Mal weiter
                break
            }
        }
    }

    /// Alles neu laden (z. B. wenn etwas kaputt ist)
    func clearOffline() {
        for name in offline { try? FileManager.default.removeItem(at: songs.appendingPathComponent(name)) }
        scan()
    }
}
