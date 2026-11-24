import Foundation
import UIKit

/// Cover in hoher Auflösung (bis 2048 px, über den Hub aus Apples Musikkatalog; sonst Spotify 640 px).
/// Einmal geladen → offline auf dem iPhone.
actor ArtStore {
    static let shared = ArtStore()
    private var memory: [String: UIImage] = [:]
    private let dir = Store.dir("CoversHD")

    private struct ArtResponse: Decodable { let url: String? }

    func file(for t: Track) -> URL { dir.appendingPathComponent("\(t.id).jpg") }

    func cached(_ t: Track) -> UIImage? {
        if let m = memory[t.id] { return m }
        if let img = UIImage(contentsOfFile: file(for: t).path) { memory[t.id] = img; return img }
        return nil
    }

    /// HD-Cover holen (falls nicht schon da). `allowNetwork` = PC/Internet darf benutzt werden.
    @discardableResult
    func image(for t: Track, allowNetwork: Bool = true) async -> UIImage? {
        if let c = cached(t) { return c }
        guard allowNetwork else { return nil }
        var url: URL?
        if let r = try? await API.get("/api/art/\(t.id)", ["a": t.artist, "n": t.title], timeout: 8, as: ArtResponse.self), let s = r.url {
            url = URL(string: s)
        }
        if url == nil, let s = t.big ?? t.cover { url = URL(string: s) }
        guard let url, let (data, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: data) else { return nil }
        try? data.write(to: file(for: t))
        memory[t.id] = img
        if memory.count > 40 { memory.removeAll() }
        return img
    }

    /// Kleine Fassung fürs Widget / die Dynamic Island in den App-Group-Ordner legen
    func exportThumb(_ t: Track) async -> String? {
        guard let img = await image(for: t), let dir = AppGroup.container else { return nil }
        let name = "cover-\(t.id).jpg"
        let target = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: target.path) {
            let size = CGSize(width: 360, height: 360)
            let thumb = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            try? thumb.jpegData(compressionQuality: 0.85)?.write(to: target)
            // alte Cover-Dateien aufräumen
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for f in files where f.hasPrefix("cover-") && f != name { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
            }
        }
        return name
    }
}
