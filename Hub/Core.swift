import Foundation
import UIKit
import CryptoKit

// MARK: - Verbindung zum Hub (Adresse + Schlüssel kommen per QR-Code / Link, nichts davon steht im Code)

enum Config {
    private static let d = UserDefaults.standard

    static var base: URL? {
        get { d.string(forKey: "base").flatMap(URL.init(string:)) }
        set { d.set(newValue?.absoluteString, forKey: "base") }
    }
    static var token: String {
        get { d.string(forKey: "token") ?? "" }
        set { d.set(newValue, forKey: "token") }
    }
    static var isSetUp: Bool { base != nil && !token.isEmpty }

    /// Akzeptiert `hubapp://setup?base=https://…&t=…` oder den Web-App-Link `https://…/music?t=…`.
    @discardableResult
    static func apply(link: URL) -> Bool {
        guard let comps = URLComponents(url: link, resolvingAgainstBaseURL: false) else { return false }
        let items = comps.queryItems ?? []
        guard let tok = items.first(where: { $0.name == "t" })?.value, !tok.isEmpty else { return false }
        var newBase: URL?
        if comps.scheme == "hubapp" {
            newBase = items.first(where: { $0.name == "base" })?.value.flatMap(URL.init(string:))
        } else if let scheme = comps.scheme, let host = comps.host {
            var c = URLComponents()
            c.scheme = scheme
            c.host = host
            c.port = comps.port
            newBase = c.url
        }
        guard let b = newBase else { return false }
        base = b
        token = tok
        return true
    }

    static func url(_ path: String, _ query: [String: String] = [:]) -> URL? {
        guard let base, var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        c.path = path
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "t", value: token)]
        return c.url
    }
}

enum API {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func post<T: Decodable>(_ path: String, body: [String: Any], timeout: TimeInterval = 10, as type: T.Type) async throws -> T {
        guard let u = Config.url(path) else { throw URLError(.badURL) }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.timeoutInterval = timeout
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], timeout: TimeInterval = 6, as type: T.Type) async throws -> T {
        guard let u = Config.url(path, query) else { throw URLError(.badURL) }
        var r = URLRequest(url: u)
        r.timeoutInterval = timeout
        let (data, resp) = try await session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Daten vom Hub

struct Fx: Codable, Hashable {
    var rate: Double?
    var bass: Double?
    var reverb: Bool?

    var label: String {
        var parts: [String] = []
        if let r = rate, abs(r - 1) > 0.001 { parts.append(String(format: "%g×", r)) }
        if let b = bass, b > 0 { parts.append("Bass \(Int(b)) %") }
        if reverb == true { parts.append("Hall") }
        return parts.joined(separator: " · ")
    }
}

struct Track: Codable, Identifiable, Hashable {
    let id: String
    let uri: String?
    let title: String
    let artist: String
    let cover: String?
    let big: String?
    let album: String?
    let duration: Double?
    let fx: Fx?
    let key: String?

    var rate: Double { fx?.rate ?? 1 }
    /// Dateiname im Offline-Speicher; ändert sich, wenn im Hub Bass/Tempo/Hall geändert wird
    var fileName: String { "\(id)__\((key ?? "1|0|0").replacingOccurrences(of: "|", with: "_")).m4a" }
}

struct PlaylistResponse: Codable {
    let name: String?
    let tracks: [Track]?
    let error: String?
}

struct WakeDay: Codable, Hashable, Identifiable {
    let date: String
    let free: Bool
    let wake: String?
    let label: String?
    let period: Int?
    let subject: String?
    var id: String { date }

    /// Weckzeit als Datum (lokale Zeitzone)
    var wakeDate: Date? {
        guard !free, let wake else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(date) \(wake)")
    }
    var dayDate: Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: date)
    }
}

struct WakeResponse: Codable {
    let days: [WakeDay]?
    let error: String?
}

struct LyricWord: Codable, Hashable {
    let ms: Double
    let text: String

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        ms = try c.decode(Double.self)
        text = (try? c.decode(String.self)) ?? ""
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(ms)
        try c.encode(text)
    }
}

struct LyricLine: Codable, Hashable {
    let ms: Double
    let text: String
    let words: [LyricWord]?

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        ms = try c.decode(Double.self)
        text = (try? c.decode(String.self)) ?? ""
        words = c.isAtEnd ? nil : (try? c.decode([LyricWord].self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(ms)
        try c.encode(text)
        if let words { try c.encode(words) }
    }
}

struct LyricsResponse: Codable {
    let lines: [LyricLine]?
    let plain: String?
    let instrumental: Bool?
    let error: String?
}

// MARK: - Ablage

enum Store {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static func dir(_ name: String) -> URL {
        let u = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func save<T: Encodable>(_ value: T, _ name: String) {
        if let d = try? JSONEncoder().encode(value) { try? d.write(to: support.appendingPathComponent(name), options: .atomic) }
    }
    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let d = try? Data(contentsOf: support.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}

// MARK: - Cover (einmal laden, dann offline)

actor CoverCache {
    static let shared = CoverCache()
    private var memory: [String: UIImage] = [:]
    private var thumbs: [String: UIImage] = [:]
    private let dir = Store.dir("Covers")

    /// verkleinerte Fassung (für Listen, Mini-Player, Hintergründe) – spart Speicher und macht Scrollen flüssig
    func image(for string: String?, px: CGFloat) async -> UIImage? {
        guard let string else { return nil }
        let key = "\(string)#\(Int(px))"
        if let t = thumbs[key] { return t }
        guard let full = await image(for: string) else { return nil }
        let t = await Self.downsample(full, px: px)
        if thumbs.count > 300 { thumbs.removeAll() }
        thumbs[key] = t
        return t
    }

    static func downsample(_ img: UIImage, px: CGFloat) async -> UIImage {
        let w = img.size.width * img.scale, h = img.size.height * img.scale
        guard max(w, h) > px * 1.2 else { return img }
        let f = px / max(w, h)
        return await img.byPreparingThumbnail(ofSize: CGSize(width: w * f, height: h * f)) ?? img
    }

    func image(for string: String?) async -> UIImage? {
        guard let string, let url = URL(string: string) else { return nil }
        if let m = memory[string] { return m }
        // eindeutiger Name aus der ganzen Adresse (Steam-Bilder heißen z. B. alle „header.jpg“)
        let digest = SHA256.hash(data: Data(string.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let file = dir.appendingPathComponent(digest + ".img")
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory[string] = img
            return img
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: data) else { return nil }
        try? data.write(to: file)
        memory[string] = img
        return img
    }
}

func formatTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let t = Int(s)
    return String(format: "%d:%02d", t / 60, t % 60)
}
