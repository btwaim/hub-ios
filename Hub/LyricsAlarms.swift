import Foundation
import SwiftUI
import AlarmKit

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

struct HubAlarmData: AlarmMetadata {}

@MainActor
final class Alarms: ObservableObject {
    static let shared = Alarms()
    enum Mode: String { case health, hub }

    @Published private(set) var days: [WakeDay] = Store.load([WakeDay].self, "wake.json") ?? []
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "alarmsOn") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "alarmsOn")
            Task { await reschedule() }
        }
    }
    /// Health-Wecker (per Kurzbefehl umgestellt) oder eigene Hub-Wecker
    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "alarmMode") ?? "health") ?? .health {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "alarmMode")
            Task { await reschedule() }
        }
    }
    @Published private(set) var status = ""
    @Published private(set) var scheduled: [String: Date] = [:]   // Datum → Weckzeit
    @Published private(set) var source = ""                       // woher die Weckzeiten stammen

    private var storedIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "alarmIDs") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "alarmIDs") }
    }

    /// Weckzeiten holen – zuerst direkt von WebUntis (ohne PC), sonst vom Hub – und Wecker neu stellen
    func refresh() async {
        if School.shared.connected {
            await School.shared.refresh()
            let d = School.shared.wakeDays()
            if !d.isEmpty { apply(d, from: "WebUntis direkt") }
        } else if let r = try? await API.get("/api/wake", timeout: 6, as: WakeResponse.self), let d = r.days, !d.isEmpty {
            apply(d, from: "Hub am PC")
        }
        await reschedule()
    }

    /// Nach dem Kurzbefehl / Hintergrund-Abruf: Tage aus dem eigenen Stundenplan übernehmen
    func refreshFromSchool() async {
        let d = School.shared.wakeDays()
        if !d.isEmpty { apply(d, from: "WebUntis direkt") }
        await reschedule()
    }

    private func apply(_ d: [WakeDay], from: String) {
        days = d
        source = from
        Store.save(d, "wake.json")
        WidgetData.writeWake(d)
    }

    /// Probe-Wecker in einer Minute (zum Testen, ob Hub-Wecker klingeln)
    func testAlarm() async {
        let manager = AlarmManager.shared
        if manager.authorizationState == .notDetermined { _ = try? await manager.requestAuthorization() }
        guard manager.authorizationState == .authorized else { status = "Wecker nicht erlaubt – Einstellungen → Hub"; return }
        let stop = AlarmButton(text: "Aus", textColor: .white, systemImageName: "stop.circle")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: "Hub-Testwecker"), stopButton: stop)
        let attributes = AlarmAttributes<HubAlarmData>(presentation: AlarmPresentation(alert: alert), tintColor: Color.purple)
        let config = AlarmManager.AlarmConfiguration<HubAlarmData>(schedule: .fixed(Date().addingTimeInterval(60)), attributes: attributes)
        do {
            _ = try await manager.schedule(id: UUID(), configuration: config)
            status = "Testwecker klingelt in einer Minute"
        } catch {
            status = "Testwecker ging nicht: \(error.localizedDescription)"
        }
    }

    func reschedule() async {
        let manager = AlarmManager.shared
        // alte Hub-Wecker entfernen
        for s in storedIDs { if let id = UUID(uuidString: s) { try? manager.cancel(id: id) } }
        storedIDs = []
        scheduled = [:]
        guard enabled else { status = "Wecker aus"; return }
        if mode == .health { status = "Health-Wecker wird per Kurzbefehl umgestellt"; return }

        switch manager.authorizationState {
        case .notDetermined:
            _ = try? await manager.requestAuthorization()
        case .denied:
            status = "Wecker nicht erlaubt – in den Einstellungen unter Hub erlauben"
            return
        default: break
        }
        guard manager.authorizationState == .authorized else { status = "Wecker nicht erlaubt"; return }

        var ids: [String] = []
        var count = 0
        for day in days {
            guard let when = day.wakeDate, when > Date() else { continue }
            let id = UUID()
            let stop = AlarmButton(text: "Aus", textColor: .white, systemImageName: "stop.circle")
            let text: String = day.period.map { "Schule · \($0). Stunde" } ?? "Aufstehen"
            let title = LocalizedStringResource(stringLiteral: text)
            let alert = AlarmPresentation.Alert(title: title, stopButton: stop)
            let attributes = AlarmAttributes<HubAlarmData>(presentation: AlarmPresentation(alert: alert), tintColor: Color.purple)
            let config = AlarmManager.AlarmConfiguration<HubAlarmData>(schedule: .fixed(when), attributes: attributes)
            do {
                _ = try await manager.schedule(id: id, configuration: config)
                ids.append(id.uuidString)
                scheduled[day.date] = when
                count += 1
            } catch {
                status = "Wecker konnte nicht gestellt werden: \(error.localizedDescription)"
            }
        }
        storedIDs = ids
        if count > 0 { status = "\(count) Wecker gestellt" }
        else if status.isEmpty || status.hasPrefix("Wecker aus") { status = "Keine Schultage mit Weckzeit gefunden" }
    }
}
