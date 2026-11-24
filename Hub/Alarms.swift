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
    /// eigene Wecktöne (mit Endung angeben – sonst spielt iOS den Standardton)
    static let soundLead = "hub-wake.caf"        // startet 3 Min vor der Weckzeit fast unhörbar, zur Weckzeit laut
    static let soundShort = "hub-wake-kurz.caf"  // 45 s von leise auf laut
    static let leadSeconds: Double = 180
    /// mögliche Weckzeiten (Hub-Regeln) – für die Zeiten der Licht-Automationen
    static let ruleTimes = ["06:25", "07:25", "08:30"]

    /// 3 Minuten sanfter Vorlauf (Studien: langsamer Anstieg → bessere Laune, nicht später wach)
    @Published var lead: Bool = UserDefaults.standard.object(forKey: "alarmLead") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(lead, forKey: "alarmLead")
            Task { await reschedule() }
        }
    }
    /// Wie viele Minuten vor dem Wecker das Aufstehlicht startet (Studien zur Morgendämmerung: meist 30 Min)
    @Published var lightLead: Int = UserDefaults.standard.object(forKey: "lightLead") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(lightLead, forKey: "lightLead") }
    }

    /// Nach wie vielen Minuten (ab Weckzeit) das Aufstehlicht von selbst ausgeht
    @Published var lightOff: Int = UserDefaults.standard.object(forKey: "lightOff") as? Int ?? 10 {
        didSet { UserDefaults.standard.set(lightOff, forKey: "lightOff") }
    }
    /// gewählte WiZ-Lampen (IDs); leer = die im Hub als „meine“ markierten
    @Published var lightLamps: [String] = UserDefaults.standard.stringArray(forKey: "lightLamps") ?? [] {
        didSet { UserDefaults.standard.set(lightLamps, forKey: "lightLamps") }
    }
    @Published private(set) var lightTestResult: String?

    private func shifted(_ minutes: Int) -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return Alarms.ruleTimes.compactMap { f.date(from: $0).map { f.string(from: $0.addingTimeInterval(Double(minutes) * 60)) } }
    }
    /// Uhrzeiten für die Licht-Automationen: an (Weckzeit − Vorlauf) und aus (Weckzeit + Aus-nach)
    var lightAutomationTimes: [String] { shifted(-lightLead) }
    var lightOffTimes: [String] { shifted(lightOff) }

    /// alle WiZ-Lampen, die der Hub kennt (zuletzt vom PC geladen)
    var knownLamps: [HubData.Lamp] { HubStore.shared.data?.lamps ?? [] }
    var activeLamps: [HubData.Lamp] {
        let all = knownLamps
        return lightLamps.isEmpty ? all.filter { $0.mine == true } : all.filter { lightLamps.contains($0.id) }
    }
    func toggleLamp(_ l: HubData.Lamp) {
        var sel = lightLamps.isEmpty ? knownLamps.filter { $0.mine == true }.map(\.id) : lightLamps
        if let i = sel.firstIndex(of: l.id) { sel.remove(at: i) } else { sel.append(l.id) }
        lightLamps = sel.isEmpty ? ["-"] : sel   // „-“ = bewusst keine Lampe
    }

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

    private func config(_ when: Date, title: String, short: Bool = false) -> AlarmManager.AlarmConfiguration<HubAlarmData> {
        let stop = AlarmButton(text: "Aus", textColor: .white, systemImageName: "sun.max.fill")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title), stopButton: stop)
        let attributes = AlarmAttributes<HubAlarmData>(presentation: AlarmPresentation(alert: alert), tintColor: Color.orange)
        let useLead = gentle && lead && !short
        let sound: AlertConfiguration.AlertSound = gentle ? .named(useLead ? Alarms.soundLead : Alarms.soundShort) : .default
        // mit Vorlauf klingelt es 3 Minuten früher ganz leise – zur eigentlichen Weckzeit ist der Ton laut
        let start = useLead ? when.addingTimeInterval(-Alarms.leadSeconds) : when
        return AlarmManager.AlarmConfiguration<HubAlarmData>(schedule: .fixed(start), attributes: attributes, sound: sound)
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
            _ = try await AlarmManager.shared.schedule(id: UUID(), configuration: config(Date().addingTimeInterval(60), title: "Hub-Testwecker", short: true))
            status = "Testwecker klingelt in einer Minute (kurze Fassung: 45 s von leise auf laut)"
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
            guard let when = day.wakeDate, when.addingTimeInterval(gentle && lead ? -Alarms.leadSeconds : 0) > Date() else { continue }
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

    // MARK: Aufstehlicht (WiZ, direkt vom iPhone)

    /// letzter Wecker, der schon geklingelt hat (für „Licht wieder aus“)
    private var lastRang: Date? {
        days.compactMap(\.wakeDate).filter { $0 <= Date() }.max()
    }

    /// Für die Automation: kurz vor dem Wecker → WiZ „Aufwachen“ an, ein paar Minuten nach dem Wecker → aus.
    /// Holt vorher den frischen Stundenplan (spontan ausgefallene 1. Stunde zählt also mit) und stellt die Wecker neu.
    func lightCheck() async -> String {
        if School.shared.connected {
            await School.shared.refresh()
            await refreshFromSchool()
        }
        let ips = activeLamps.map(\.ip)
        var on = false
        var note: String
        if ips.isEmpty {
            note = "Keine WiZ-Lampe gewählt (Hub → Wecker → Aufstehlicht)"
        } else if let t = lightTestUntil, t > Date() {
            let n = await WiZ.wake(ips); on = true
            note = "Test: Aufwachen an (\(n)/\(ips.count) Lampen)"
        } else if let n = next, enabled, abs(n.at.timeIntervalSinceNow / 60 - Double(lightLead)) <= 8 {
            let ok = await WiZ.wake(ips); on = true
            note = "Wecker \(n.at.formatted(date: .omitted, time: .shortened)) → Aufwachen an (\(ok)/\(ips.count) Lampen)"
        } else if let r = lastRang, abs(-r.timeIntervalSinceNow / 60 - Double(lightOff)) <= 8 {
            let ok = await WiZ.off(ips)
            note = "Wecker war \(r.formatted(date: .omitted, time: .shortened)) → Licht aus (\(ok)/\(ips.count) Lampen)"
        } else {
            note = next.map { "Wecker erst \($0.at.formatted(date: .omitted, time: .shortened)) – nichts zu tun" } ?? "Kein Wecker geplant – nichts zu tun"
        }
        let c = LightCheck(at: Date(), on: on, note: note)
        lastLight = c
        Store.save(c, "lightcheck.json")
        return note
    }

    /// Test direkt in der App (fragt beim ersten Mal nach „Lokales Netzwerk“)
    func testLight(_ wake: Bool) async {
        let ips = activeLamps.map(\.ip)
        guard !ips.isEmpty else { lightTestResult = "Keine Lampe gewählt"; return }
        var ok = 0
        if wake { ok = await WiZ.wake(ips) } else { ok = await WiZ.off(ips) }
        lightTestResult = ok == 0 ? "Keine Antwort – iPhone im selben WLAN? In der WiZ-App „Lokale Kommunikation“ an? Hub darf aufs lokale Netzwerk?"
                                  : "\(ok)/\(ips.count) Lampen: \(wake ? "Aufwachen an" : "aus")"
    }

    /// 10 Minuten lang schaltet die Automation sofort an (zum Testen mit der echten Automation)
    func startLightTest() {
        let until = Date().addingTimeInterval(600)
        lightTestUntil = until
        UserDefaults.standard.set(until, forKey: "lightTest")
    }
}

// MARK: - Kurzbefehl-Aktion für das WiZ-Aufstehlicht (direkt in der Automation auswählbar, kein eigener Kurzbefehl nötig)

struct WakeLightIntent: AppIntent {
    static var title: LocalizedStringResource = "Aufstehlicht"
    static var description = IntentDescription("Schaltet kurz vor deinem Hub-Wecker das WiZ-„Aufwachen“ ein und ein paar Minuten nach dem Wecker wieder aus. Holt dafür den aktuellen Stundenplan, auch ohne PC.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let note = await Alarms.shared.lightCheck()
        return .result(value: note)
    }
}

