import Foundation
import ActivityKit
import AppIntents
import UIKit

// MARK: - App Group (iloader legt sie als „group.<Bundle-ID der App>“ an – wir rechnen den Namen zur Laufzeit aus)

enum AppGroup {
    static var id: String {
        var bid = Bundle.main.bundleIdentifier ?? "app.hubmusic.hub"
        // In der Widget-Erweiterung ist die Bundle-ID „<App>.Widgets“ → letzten Teil abschneiden
        if Bundle.main.bundleURL.pathExtension == "appex", let dot = bid.lastIndex(of: ".") { bid = String(bid[..<dot]) }
        return "group.\(bid)"
    }
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }
    static var defaults: UserDefaults? { UserDefaults(suiteName: id) }

    static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let dir = container, let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }
    static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let dir = container, let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    static func image(_ name: String) -> UIImage? {
        guard let dir = container else { return nil }
        return UIImage(contentsOfFile: dir.appendingPathComponent(name).path)
    }
}

// MARK: - Daten für Widgets

struct WidgetLyric: Codable, Hashable {
    let at: Date        // wann die Zeile beginnt (absolute Zeit, solange der Song läuft)
    let text: String
}

struct WidgetNowPlaying: Codable, Hashable {
    var title: String
    var artist: String
    var isPlaying: Bool
    var start: Date?      // Songbeginn (für Fortschritt), nur gültig wenn isPlaying
    var end: Date?
    var lyrics: [WidgetLyric]
    var coverFile: String?   // im App-Group-Ordner
    var fx: String
}

struct WidgetDay: Codable, Hashable {
    let date: String
    let free: Bool
    let wake: String?
    let label: String
    let period: Int?
    let subject: String?
}

struct WidgetShow: Codable, Hashable {
    let title: String
    let progress: String
    let pct: Double?
    let newEp: Bool
    let imageFile: String?
}

// MARK: - Live Activity (Sperrbildschirm + Dynamic Island)

struct NowPlayingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var isPlaying: Bool
        var lyric: String
        var nextLyric: String
        var start: Date?
        var end: Date?
        var coverFile: String?
        var fx: String
        var elapsed: Double = 0     // Position beim letzten Update (für pausiert)
        var duration: Double = 0
    }
    var name: String = "Hub"
}

extension NowPlayingAttributes.ContentState {
    /// Fortschritt 0…1, wenn pausiert
    var pausedProgress: Double { duration > 0 ? min(1, max(0, elapsed / duration)) : 0 }
    /// Gültiger Zeitraum für laufende Fortschrittsbalken
    var range: ClosedRange<Date>? {
        guard isPlaying, let s = start, let e = end, e > s else { return nil }
        return s...e
    }
}

extension WidgetNowPlaying {
    var range: ClosedRange<Date>? {
        guard isPlaying, let s = start, let e = end, e > s, e > Date() else { return nil }
        return s...e
    }
}

// MARK: - Steuerung aus Widget / Dynamic Island (läuft im App-Prozess, weil es Audio-Intents sind)

@MainActor
final class HubControl {
    static let shared = HubControl()
    var handler: ((String) -> Void)?
    func run(_ cmd: String) { handler?(cmd) }
}

struct TogglePlayIntent: AudioPlaybackIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Play/Pause"
    static var isDiscoverable: Bool = false
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run { HubControl.shared.run("toggle") }
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Nächster Song"
    static var isDiscoverable: Bool = false
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run { HubControl.shared.run("next") }
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Vorheriger Song"
    static var isDiscoverable: Bool = false
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run { HubControl.shared.run("prev") }
        return .result()
    }
}
