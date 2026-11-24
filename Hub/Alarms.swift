import Foundation
import SwiftUI
import AlarmKit
import ActivityKit
import AppIntents

// Wecker nach Stundenplan: echte iPhone-Wecker über AlarmKit (klingeln auch ohne PC und wenn die App zu ist),
// mit eigenem Ton, der leise anfängt und lauter wird. Dazu das WiZ-Aufstehlicht 10 Minuten vorher (per Kurzbefehl).

struct HubAlarmData: AlarmMetadata {}

@MainActor
final class Alarms: ObservableObject {
    static let shared = Alarms()
    /// eigener Weckton (Resources/hub-wake.caf, mit Endung angeben – sonst spielt iOS den Standardton)
    static let soundFile = "hub-wake.caf"

    @Published private(set) var days: [WakeDay] = Store.load([WakeDay].self, "wake.json") ?? []
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "alarmsOn") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "alarmsOn")
            Task { await reschedule() }
        }
    }
    /// sanft lauter werdender Hub-Ton oder normaler iPhone-Ton
    @Published var gentle: Bool = UserDefaults.standard.object(forKey: "alarmGentle") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(gentle, forKey: "alarmGentle")
            Task { await reschedule() }
        }
    }
    @Published private(set) var status = ""
    @Published private(set) var scheduled: [String: Date] = [:]   // Datum → Weckzeit
    @Published private(set) var source = ""

    // Aufstehlicht (WiZ)
    struct LightCheck: Codable { let at: Date; let on: Bool; let note: String }
    @Published private(set) var lastLight: LightCheck? = Store.load(LightCheck.self, "lightcheck.json")
    /// Test: Bis zu diesem Zeitpunkt sagt die Prüfung immer „Licht an“
    @Published private(set) var lightTestUntil: Date? = UserDefaults.standard.object(forKey: "lightTest") as? Date

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

    /// nur Vorführmodus
    func demo(_ d: [WakeDay]) { days = d }

    /// Nach Kurzbefehl / Hintergrund-Abruf: Tage aus dem eigenen Stundenplan übernehmen
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

    /// nächster Wecker (Zeit + Tag)
    var next: (at: Date, day: WakeDay)? {
        days.compactMap { d in d.wakeDate.map { (at: $0, day: d) } }.filter { $0.at > Date() }.min { $0.at < $1.at }
    }

    private func config(_ when: Date, title: String) -> AlarmManager.AlarmConfiguration<HubAlarmData> {
        let stop = AlarmButton(text: "Aus", textColor: .white, systemImageName: "sun.max.fill")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title), stopButton: stop)
        let attributes = AlarmAttributes<HubAlarmData>(presentation: AlarmPresentation(alert: alert), tintColor: Color.orange)
        let sound: AlertConfiguration.AlertSound = gentle ? .named(Alarms.soundFile) : .default
        return AlarmManager.AlarmConfiguration<HubAlarmData>(schedule: .fixed(when), attributes: attributes, sound: sound)
    }

    private func authorized() async -> Bool {
        let manager = AlarmManager.shared
        if manager.authorizationState == .notDetermined { _ = try? await manager.requestAuthorization() }
        if manager.authorizationState == .denied { status = "Wecker nicht erlaubt – Einstellungen → Hub → Wecker erlauben"; return false }
        return manager.authorizationState == .authorized
    }

    /// Probe-Wecker in einer Minute (mit dem gewählten Ton)
    func testAlarm() async {
        guard await authorized() else { return }
        do {
            _ = try await AlarmManager.shared.schedule(id: UUID(), configuration: config(Date().addingTimeInterval(60), title: "Hub-Testwecker"))
            status = "Testwecker klingelt in einer Minute"
        } catch {
            status = "Testwecker ging nicht: \(error.localizedDescription)"
        }
    }

    func reschedule() async {
        let manager = AlarmManager.shared
        for s in storedIDs { if let id = UUID(uuidString: s) { try? manager.cancel(id: id) } }
        storedIDs = []
        scheduled = [:]
        guard enabled else { status = "Wecker aus"; return }
        guard await authorized() else { if status.isEmpty { status = "Wecker nicht erlaubt" }; return }

        var ids: [String] = []
        for day in days {
            guard let when = day.wakeDate, when > Date() else { continue }
            let id = UUID()
            let title = day.period.map { "Guten Morgen · \($0). Stunde\(day.subject.map { " \($0)" } ?? "")" } ?? "Guten Morgen"
            do {
                _ = try await manager.schedule(id: id, configuration: config(when, title: title))
                ids.append(id.uuidString)
                scheduled[day.date] = when
            } catch {
                status = "Wecker konnte nicht gestellt werden: \(error.localizedDescription)"
            }
        }
        storedIDs = ids
        if !ids.isEmpty { status = "\(ids.count) Wecker gestellt" }
        else if status.isEmpty || status.hasPrefix("Wecker aus") { status = "Keine Schultage mit Weckzeit gefunden" }
    }

    // MARK: Aufstehlicht

    /// Für den Kurzbefehl: Klingelt der Wecker in den nächsten ~20 Minuten? Holt vorher den frischen Stundenplan
    /// (so wird eine spontan ausgefallene 1. Stunde noch berücksichtigt) und stellt die Wecker neu.
    func lightCheck() async -> Bool {
        if School.shared.connected {
            await School.shared.refresh()
            await refreshFromSchool()
        }
        var on = false
        var note: String
        if let t = lightTestUntil, t > Date() {
            on = true
            note = "Test: Licht an"
        } else if let n = next {
            let mins = n.at.timeIntervalSinceNow / 60
            on = enabled && mins >= 2 && mins <= 22
            let time = n.at.formatted(date: .omitted, time: .shortened)
            note = on ? "Wecker \(time) → Aufstehlicht an" : "Wecker erst \(time) – noch kein Licht"
        } else {
            note = "Kein Wecker geplant – kein Licht"
        }
        let c = LightCheck(at: Date(), on: on, note: note)
        lastLight = c
        Store.save(c, "lightcheck.json")
        return on
    }

    /// 10 Minuten lang sagt die Prüfung „an“ → Kurzbefehl einmal von Hand starten zum Testen
    func startLightTest() {
        let until = Date().addingTimeInterval(600)
        lightTestUntil = until
        UserDefaults.standard.set(until, forKey: "lightTest")
    }
}

// MARK: - Kurzbefehl-Aktion für das WiZ-Aufstehlicht

struct WakeLightIntent: AppIntent {
    static var title: LocalizedStringResource = "Aufstehlicht prüfen"
    static var description = IntentDescription("Ja, wenn dein Hub-Wecker in den nächsten Minuten klingelt (holt dafür den aktuellen Stundenplan, auch ohne PC). Danach im Kurzbefehl dein WiZ-Aufstehlicht einschalten.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let on = await Alarms.shared.lightCheck()
        return .result(value: on)
    }
}
