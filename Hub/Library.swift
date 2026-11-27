import Foundation
import UIKit
import WidgetKit

struct HubState: Codable {
    struct Lesson: Codable, Hashable { let start: String?; let subject: String?; let room: String?; let kind: String? }
    struct School: Codable, Hashable { let label: String?; let lessons: [Lesson]? }
    struct Show: Codable, Hashable, Identifiable { let id: String; let title: String; let image: String?; let progress: String?; let pct: Double?; let newEp: Bool? }
    struct Exam: Codable, Hashable { let title: String; let when: String? }
    struct Ev: Codable, Hashable { let title: String; let type: String?; let when: String? }
    let greeting: String?
    let sleep: String?
    let school: School?
    let watch: [Show]?
    let gta: String?
    let nextExam: Exam?
    let events: [Ev]?
}

/// Playlist + Offline-Speicher. Songs kommen vom Hub schon im Hub-Sound (Bass/Tempo/Hall eingerechnet).
@MainActor
final class Library: ObservableObject {
    static let shared = Library()
    struct Progress: Equatable { var done: Int; var total: Int; var title: String }

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var offline: Set<String> = []
    @Published private(set) var pcOnline = false
    @Published private(set) var syncing = false
    @Published private(set) var progress: Progress?
    @Published private(set) var lastError: String?
    /// Am Handy geänderte Effekte, die noch zum PC müssen (Song-ID → Effekte)
    @Published private(set) var pending: [String: Fx] = [:]
    @Published private(set) var hub: HubState? = Store.load(HubState.self, "hubstate.json")

    private let songs = Store.dir("Songs")
    /// welche Effekte in welcher Datei stecken (Dateiname → Effekte)
    private var baked: [String: Fx] = Store.load([String: Fx].self, "baked.json") ?? [:]

    init() {
        tracks = Store.load([Track].self, "playlist.json") ?? []
        pending = Store.load([String: Fx].self, "pending.json") ?? [:]
        scan()
    }

    var offlineCount: Int { tracks.filter { offline.contains($0.fileName) }.count }
    var storageMB: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: songs, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return bytes / 1_000_000
    }

    func isOffline(_ t: Track) -> Bool { offline.contains(t.fileName) || offline.contains { $0.hasPrefix(t.id + "__") } }
    func streamURL(_ t: Track) -> URL? { Config.url("/hsong/\(t.id)", ["k": t.key ?? "1|0|0|256"]) }

    /// Effekte, die der Song haben soll (Änderung am Handy hat Vorrang)
    func desiredFx(_ t: Track) -> Fx { pending[t.id] ?? t.fx ?? Fx(rate: 1, bass: 0, reverb: false) }

    /// Abspielbare Datei + die Effekte, die darin schon stecken
    func localFile(_ t: Track) -> (url: URL, baked: Fx)? {
        let fallback = t.fx ?? Fx(rate: 1, bass: 0, reverb: false)
        if offline.contains(t.fileName) { return (songs.appendingPathComponent(t.fileName), baked[t.fileName] ?? fallback) }
        if let old = offline.first(where: { $0.hasPrefix(t.id + "__") }) {
            return (songs.appendingPathComponent(old), baked[old] ?? Fx(rate: 1, bass: 0, reverb: false))
        }
        return nil
    }

    private func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: songs.path)) ?? []
        offline = Set(names.filter { $0.hasSuffix(".m4a") })
    }

    // MARK: Effekte vom Handy

    func setFx(_ t: Track, _ fx: Fx) {
        pending[t.id] = fx
        Store.save(pending, "pending.json")
        if pcOnline { Task { await pushPending() } }
    }

    /// Änderungen zum PC schicken → PC rechnet den exakten Hub-Sound → neue Datei laden
    func pushPending() async {
        guard !pending.isEmpty else { return }
        struct FxResponse: Decodable { let key: String?; let error: String? }
        var changed = false
        for (id, fx) in pending {
            let body: [String: Any] = ["id": id, "rate": fx.rate ?? 1, "bass": fx.bass ?? 0, "reverb": fx.reverb ?? false]
            if let r = try? await API.post("/api/fx", body: body, as: FxResponse.self), r.error == nil {
                pending[id] = nil
                changed = true
            }
        }
        Store.save(pending, "pending.json")
        if changed { await refresh() }
    }

    // MARK: Abgleich mit dem PC

    /// Playlist vom PC holen (falls erreichbar) und fehlende Songs herunterladen
    func refresh() async {
        guard Config.isSetUp else { return }
        do {
            let p = try await API.get("/api/playlist", timeout: 6, as: PlaylistResponse.self)
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
        guard pcOnline else { return }
        await GameBridge.syncInBackground()   // Ashen Oath: Spielstand mit dem PC abgleichen
        if !pending.isEmpty { await pushPending(); return }
        await loadHubState()
        await sync()
    }

    func loadHubState() async {
        guard let s = try? await API.get("/api/state", timeout: 6, as: HubState.self) else { return }
        hub = s
        Store.save(s, "hubstate.json")
        WidgetData.writeWatch(s.watch ?? [])
    }

    func sync() async {
        guard pcOnline, !syncing else { return }
        syncing = true
        let bg = UIApplication.shared.beginBackgroundTask(withName: "songs")
        defer {
            syncing = false
            progress = nil
            UIApplication.shared.endBackgroundTask(bg)
        }
        scan()
        let todo = tracks.filter { !offline.contains($0.fileName) }
        var done = tracks.count - todo.count
        var aborted = false
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
                baked[t.fileName] = t.fx ?? Fx(rate: 1, bass: 0, reverb: false)
                Store.save(baked, "baked.json")
                done += 1
            } catch {
                pcOnline = false
                aborted = true
                break
            }
        }
        // alte Fassungen erst löschen, wenn die neue da ist (so bleibt alles spielbar)
        let current = Set(tracks.map(\.fileName))
        let ids = Set(tracks.map(\.id))
        for name in offline where !current.contains(name) {
            let id = String(name.split(separator: "_").first ?? "")
            let replacementReady = tracks.first { $0.id == id }.map { offline.contains($0.fileName) } ?? true
            if !ids.contains(id) || replacementReady {
                try? FileManager.default.removeItem(at: songs.appendingPathComponent(name))
                baked[name] = nil
            }
        }
        Store.save(baked, "baked.json")
        scan()
        // HD-Cover vorab laden (für unterwegs)
        if !aborted {
            for t in tracks { await ArtStore.shared.image(for: t) }
        }
    }

    /// nur Vorführmodus (Simulator-Screenshots)
    func demo(_ t: [Track]) { tracks = t }
    func demoHub(_ s: HubState) { hub = s }

    /// Alles neu laden (z. B. wenn etwas kaputt ist)
    func clearOffline() {
        for name in offline { try? FileManager.default.removeItem(at: songs.appendingPathComponent(name)) }
        baked = [:]
        Store.save(baked, "baked.json")
        scan()
    }
}
