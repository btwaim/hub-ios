import Foundation
import UIKit

/// Cover in hoher Auflösung. Reihenfolge: gespeichertes HD-Cover → HD vom Hub (2048 px, nur bei sicherem Treffer)
/// → Spotify-Cover (640 px, braucht nur Internet) → kleines Cover. Einmal geladen → offline auf dem iPhone.
actor ArtStore {
    static let shared = ArtStore()
    private var memory: [String: UIImage] = [:]
    private var loading: [String: Task<UIImage?, Never>] = [:]
    /// neuer Ordner: alte, teils falsche Treffer werden nicht mehr benutzt
    private let dir = Store.dir("CoversHD2")

    private struct ArtResponse: Decodable { let url: String? }

    init() {
        // alten Ordner mit teils falschen Covern aufräumen
        try? FileManager.default.removeItem(at: Store.support.appendingPathComponent("CoversHD"))
    }

    func file(for t: Track) -> URL { dir.appendingPathComponent("\(t.id).jpg") }

    func cached(_ t: Track) -> UIImage? {
        if let m = memory[t.id] { return m }
        if let img = UIImage(contentsOfFile: file(for: t).path) { remember(t.id, img); return img }
        return nil
    }

    private func remember(_ id: String, _ img: UIImage) {
        if memory.count > 60 { memory.removeAll() }
        memory[id] = img
    }

    private var thumbs: [String: UIImage] = [:]

    /// Bestes Cover, verkleinert auf `px` Pixel (Mini-Player, Kopfzeilen, unscharfe Hintergründe)
    func thumb(for t: Track, px: CGFloat, allowNetwork: Bool = true) async -> UIImage? {
        let key = "\(t.id)#\(Int(px))"
        if let c = thumbs[key] { return c }
        guard let full = await image(for: t, allowNetwork: allowNetwork) else { return nil }
        let small = await CoverCache.downsample(full, px: px)
        if thumbs.count > 200 { thumbs.removeAll() }
        thumbs[key] = small
        return small
    }

    /// Bestes verfügbares Cover. `allowNetwork` = Hub (PC) darf gefragt werden; Spotify geht auch ohne PC.
    @discardableResult
    func image(for t: Track, allowNetwork: Bool = true) async -> UIImage? {
        if let c = cached(t) { return c }
        if let running = loading[t.id] { return await running.value }
        let job = Task<UIImage?, Never> { await self.fetch(t, askHub: allowNetwork) }
        loading[t.id] = job
        let img = await job.value
        loading[t.id] = nil
        return img
    }

    private func fetch(_ t: Track, askHub: Bool) async -> UIImage? {
        var hubAnswered = false
        var url: URL?
        if askHub, let r = try? await API.get("/api/art/\(t.id)", ["a": t.artist, "n": t.title, "b": t.album ?? ""], timeout: 8, as: ArtResponse.self) {
            hubAnswered = true
            url = r.url.flatMap(URL.init(string:))
        }
        if let url, let (data, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: data) {
            try? data.write(to: file(for: t))
            remember(t.id, img)
            return img
        }
        // Spotify-Cover: endgültig speichern, wenn der Hub gesagt hat „kein besseres“, sonst nur zwischendurch zeigen
        if let s = t.big ?? t.cover, let u = URL(string: s), let (data, _) = try? await URLSession.shared.data(from: u), let img = UIImage(data: data) {
            if hubAnswered { try? data.write(to: file(for: t)) }
            remember(t.id, img)
            return img
        }
        return await CoverCache.shared.image(for: t.cover)
    }

    /// Kleine Fassung fürs Widget / die Dynamic Island in den App-Group-Ordner legen
    func exportThumb(_ t: Track) async -> String? {
        guard let img = await image(for: t), let dir = AppGroup.container else { return nil }
        // klein halten: Live-Aktivitäten/Dynamic Island zeichnen zu große Bilder gar nicht (grauer Kreis)
        let name = "thumb-\(t.id).jpg"
        let target = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: target.path) {
            let size = CGSize(width: 120, height: 120)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let thumb = UIGraphicsImageRenderer(size: size, format: format).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            try? thumb.jpegData(compressionQuality: 0.75)?.write(to: target)
            // alte Cover-Dateien aufräumen
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for f in files where (f.hasPrefix("cover-") || f.hasPrefix("art-") || f.hasPrefix("thumb-")) && f != name {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
                }
            }
        }
        return name
    }
}
