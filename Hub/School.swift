import Foundation
import CryptoKit
import Security
import AppIntents
import BackgroundTasks
import WidgetKit

// Stundenplan direkt von WebUntis – ohne PC. Zugang über den QR-Code aus WebUntis (Profil → Freigaben → Untis Mobile),
// wie bei der offiziellen Untis-App: Benutzer + geheimer Schlüssel, daraus jede halbe Minute ein Einmal-Code.
// Der Schlüssel liegt nur im iPhone-Schlüsselbund.

struct UntisLogin: Codable, Equatable {
    var server: String      // z. B. realschule-vechelde.webuntis.com
    var school: String
    var user: String
    var key: String

    /// `untis://setschool?url=…&school=…&user=…&key=…`
    static func parse(_ text: String) -> UntisLogin? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: t), let items = c.queryItems else { return nil }
        func v(_ n: String) -> String? { items.first { $0.name.lowercased() == n.lowercased() }?.value?.trimmingCharacters(in: .whitespaces) }
        guard var server = v("url"), let school = v("school"), let user = v("user"), let key = v("key"), !key.isEmpty else { return nil }
        server = server.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        while server.hasSuffix("/") { server.removeLast() }
        return UntisLogin(server: server, school: school, user: user, key: key)
    }
}

enum Keychain {
    private static let service = "hub.untis"
    static func save(_ data: Data, _ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        // auch bei gesperrtem iPhone lesbar (Kurzbefehl um 5:30), aber erst nach dem ersten Entsperren seit dem Start
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func load(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

struct SchoolLesson: Codable, Hashable {
    let date: String
    let start: String
    let end: String
    let kind: String        // normal, cancel, movedAway, movedIn, extra, exam, change, room
    let subject: String
    let room: String
    var period: Int?

    var isOff: Bool { kind == "cancel" || kind == "movedAway" }
}

enum UntisAPI {
    enum Failure: LocalizedError {
        case login(String), http(String, Int), format(String)
        var errorDescription: String? {
            switch self {
            case .login(let m): return "Anmeldung abgelehnt: \(m)"
            case .http(let w, let c): return "\(w) nicht abrufbar (HTTP \(c))"
            case .format(let m): return m
            }
        }
    }

    /// Einmal-Code (TOTP, 6 Ziffern, 30 s, SHA1) aus dem geheimen Schlüssel
    static func totp(_ secret: String, at date: Date = Date()) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var bytes: [UInt8] = []
        for ch in secret.uppercased() where ch != "=" && ch != " " {
            guard let i = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | i
            bits += 5
            if bits >= 8 { bytes.append(UInt8((value >> (bits - 8)) & 0xff)); bits -= 8 }
        }
        guard !bytes.isEmpty else { return nil }
        var counter = UInt64(date.timeIntervalSince1970 / 30).bigEndian
        let msg = Data(bytes: &counter, count: 8)
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: SymmetricKey(data: Data(bytes))))
        let o = Int(mac[mac.count - 1] & 0x0f)
        let code = (UInt32(mac[o] & 0x7f) << 24) | (UInt32(mac[o + 1]) << 16) | (UInt32(mac[o + 2]) << 8) | UInt32(mac[o + 3])
        return String(format: "%06d", code % 1_000_000)
    }

    /// Anmelden und den Stundenplan für einen Zeitraum holen (gleiche Abfrage wie der Hub am PC)
    static func fetch(_ login: UntisLogin, start: String, end: String) async throws -> (person: String, data: [String: Any]) {
        let base = "https://\(login.server)"
        let cfg = URLSessionConfiguration.ephemeral
        // WebUntis erwartet die Schule zusätzlich als Cookie
        if let host = URL(string: base)?.host,
           let cookie = HTTPCookie(properties: [.domain: host, .path: "/", .name: "schoolname",
                                                .value: "\"_\(Data(login.school.utf8).base64EncodedString())\"", .secure: "TRUE"]) {
            cfg.httpCookieStorage?.setCookie(cookie)
        }
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        guard let otp = totp(login.key) else { throw Failure.format("Der Schlüssel aus dem QR-Code ist ungültig") }
        var comps = URLComponents(string: base + "/WebUntis/jsonrpc_intern.do")!
        comps.queryItems = [URLQueryItem(name: "m", value: "getUserData2017"), URLQueryItem(name: "school", value: login.school), URLQueryItem(name: "v", value: "i2.2")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["id": "hub", "method": "getUserData2017", "jsonrpc": "2.0",
                                   "params": [["auth": ["clientTime": Int(Date().timeIntervalSince1970 * 1000), "user": login.user, "otp": otp]]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (ld, lr) = try await session.data(for: req)
        let lj = (try? JSONSerialization.jsonObject(with: ld)) as? [String: Any]
        if let e = lj?["error"] as? [String: Any] { throw Failure.login(e["message"] as? String ?? "unbekannt") }
        guard (lr as? HTTPURLResponse)?.statusCode == 200, lj?["result"] != nil else { throw Failure.http("Anmeldung", (lr as? HTTPURLResponse)?.statusCode ?? 0) }

        // Token für die neue Schnittstelle (wie die WebUntis-Webseite)
        var tr = URLRequest(url: URL(string: base + "/WebUntis/api/token/new")!)
        tr.timeoutInterval = 15
        let (td, tresp) = try await session.data(for: tr)
        let token = String(decoding: td, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (tresp as? HTTPURLResponse)?.statusCode == 200, token.split(separator: ".").count == 3 else {
            throw Failure.http("Zugangs-Token", (tresp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        func get(_ path: String) async throws -> [String: Any] {
            var r = URLRequest(url: URL(string: base + path)!)
            r.timeoutInterval = 20
            r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            let (d, resp) = try await session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { throw Failure.http(path.contains("timetable") ? "Stundenplan" : "Profil", code) }
            return j
        }
        let me = try await get("/WebUntis/api/rest/view/v1/app/data")
        guard let person = (me["user"] as? [String: Any])?["person"] as? [String: Any], let pid = (person["id"] as? NSNumber)?.intValue else {
            throw Failure.format("Konnte dein Schülerprofil nicht lesen")
        }
        let data = try await get("/WebUntis/api/rest/view/v1/timetable/entries?start=\(start)&end=\(end)&format=4&resourceType=STUDENT&resources=\(pid)&periodTypes=&timetableType=MY_TIMETABLE")
        return (person["displayName"] as? String ?? login.user, data)
    }

    /// WebUntis-Antwort → einfache Stunden (wie parseWeek im Hub)
    static func parse(_ data: [String: Any]) -> [SchoolLesson] {
        var out: [SchoolLesson] = []
        let examRx = try? NSRegularExpression(pattern: "arbeit|klausur|test|prüfung|lernkontrolle", options: .caseInsensitive)
        for day in data["days"] as? [[String: Any]] ?? [] {
            let date = String((day["date"] as? String ?? "").prefix(10))
            for e in day["gridEntries"] as? [[String: Any]] ?? [] {
                let pos: [[String: Any]] = e.keys.filter { $0.hasPrefix("position") && Int($0.dropFirst(8)) != nil }
                    .flatMap { (e[$0] as? [Any] ?? []).compactMap { $0 as? [String: Any] } }
                func pick(_ type: String, _ which: String = "current") -> [[String: Any]] {
                    pos.compactMap { $0[which] as? [String: Any] }.filter { ($0["type"] as? String ?? "").uppercased() == type }
                }
                func nm(_ x: [String: Any]) -> String {
                    for k in ["shortName", "displayName", "longName"] { if let s = x[k] as? String, !s.isEmpty { return s } }
                    return ""
                }
                let subj = pick("SUBJECT").first ?? pick("SUBJECT", "removed").first
                let rooms = pick("ROOM").isEmpty ? pick("ROOM", "removed") : pick("ROOM")
                let rmT = pick("TEACHER", "removed"), rmR = pick("ROOM", "removed")
                let st = [e["status"], e["statusDetail"], e["type"]].map { ($0 as? String) ?? "" }.joined(separator: " ").uppercased()
                var kind = "normal"
                if st.contains("CANCEL") { kind = st.contains("MOVED") ? "movedAway" : "cancel" }
                else if st.contains("ADDITIONAL") { kind = st.contains("MOVED") ? "movedIn" : "extra" }
                else if st.contains("EXAM") { kind = "exam" }
                else if !rmT.isEmpty || st.contains("SUBST") || st.contains("CHANGE") { kind = !rmT.isEmpty || rmR.isEmpty ? "change" : "room" }
                else if !rmR.isEmpty { kind = "room" }
                var texts = [e["substitutionText"], e["lessonText"], e["notesAll"]].compactMap { $0 as? String }
                texts += (e["texts"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                let all = texts.joined(separator: " ")
                if kind != "cancel" && kind != "movedAway", let rx = examRx, rx.firstMatch(in: all, range: NSRange(all.startIndex..., in: all)) != nil { kind = "exam" }
                let dur = e["duration"] as? [String: Any]
                func hm(_ s: Any?) -> String { let t = s as? String ?? ""; return t.count >= 16 ? String(t.dropFirst(11).prefix(5)) : "" }
                let subject = subj.map(nm) ?? (e["name"] as? String ?? "–")
                out.append(SchoolLesson(date: date, start: hm(dur?["start"]), end: hm(dur?["end"]), kind: kind,
                                        subject: subject.isEmpty ? "–" : subject, room: rooms.map(nm).joined(separator: ", ")))
            }
        }
        out.sort { ($0.date + $0.start) < ($1.date + $1.start) }
        // Stundennummer aus dem Raster (ohne Zusatz-/Verlegungsstunden)
        let starts = Array(Set(out.filter { $0.kind != "movedIn" && $0.kind != "extra" }.map(\.start))).sorted()
        for i in out.indices { out[i].period = starts.firstIndex(of: out[i].start).map { $0 + 1 } }
        return out
    }
}

/// Weckzeit nach der ersten echten Stunde – dieselben Regeln wie im Hub
struct WakePlan: Equatable {
    let date: String
    let free: Bool
    let wake: String?          // "06:25"
    let period: Int?
    let subject: String?
    let off: String?           // offline gehen
    let latest: String?        // spätestens schlafen

    var wakeDate: Date? {
        guard !free, let wake else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(date) \(wake)")
    }
}

@MainActor
final class School: ObservableObject {
    static let shared = School()
    static let rules: [Int: (off: String, latest: String, wake: String)] = [
        1: ("22:00", "22:30", "06:25"),
        2: ("23:00", "23:30", "07:25"),
        3: ("00:00", "00:00", "08:30")
    ]

    @Published private(set) var login: UntisLogin?
    @Published private(set) var person: String? = UserDefaults.standard.string(forKey: "untisPerson")
    @Published private(set) var lessons: [SchoolLesson] = Store.load([SchoolLesson].self, "lessons.json") ?? []
    @Published private(set) var range: [String] = UserDefaults.standard.stringArray(forKey: "untisRange") ?? []    // [start, end]
    @Published private(set) var lastFetch: Date? = UserDefaults.standard.object(forKey: "untisFetched") as? Date
    @Published private(set) var lastError: String?
    @Published private(set) var loading = false

    init() {
        if let d = Keychain.load("login") { login = try? JSONDecoder().decode(UntisLogin.self, from: d) }
    }

    var connected: Bool { login != nil }

    func connect(_ text: String) async -> Bool {
        guard let l = UntisLogin.parse(text) else { lastError = "Das ist kein WebUntis-QR-Code (untis://setschool…)"; return false }
        login = l
        if let d = try? JSONEncoder().encode(l) { Keychain.save(d, "login") }
        let ok = await refresh()
        if !ok { login = nil; Keychain.delete("login") }
        return ok
    }

    func disconnect() {
        Keychain.delete("login")
        login = nil
        person = nil
        UserDefaults.standard.removeObject(forKey: "untisPerson")
    }

    private static func iso(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Diese + nächste Woche von WebUntis holen
    @discardableResult
    func refresh() async -> Bool {
        guard let l = login, !loading else { return false }
        loading = true
        defer { loading = false }
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let now = Date()
        let monday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
        let end = cal.date(byAdding: .day, value: 13, to: monday) ?? now
        let s = Self.iso(monday), e = Self.iso(end)
        do {
            let r = try await UntisAPI.fetch(l, start: s, end: e)
            let parsed = UntisAPI.parse(r.data)
            lessons = parsed
            range = [s, e]
            person = r.person
            lastFetch = Date()
            lastError = nil
            Store.save(parsed, "lessons.json")
            UserDefaults.standard.set([s, e], forKey: "untisRange")
            UserDefaults.standard.set(lastFetch, forKey: "untisFetched")
            UserDefaults.standard.set(r.person, forKey: "untisPerson")
            WidgetData.writeWake(wakeDays().map { Alarms.applying(Alarms.shared.overrides[$0.date], to: $0) })
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Plan für einen Tag (nil = Stundenplan für diesen Tag nicht geladen)
    func plan(for date: String) -> WakePlan? {
        guard range.count == 2, date >= range[0], date <= range[1] else { return nil }
        let have = lessons.filter { $0.date == date && !$0.isOff }
        guard let first = have.min(by: { $0.start < $1.start }) else {
            return WakePlan(date: date, free: true, wake: nil, period: nil, subject: nil, off: nil, latest: nil)
        }
        let p = min(first.period ?? 3, 3)
        let r = Self.rules[p] ?? Self.rules[3]!
        return WakePlan(date: date, free: false, wake: r.wake, period: first.period, subject: first.subject, off: r.off, latest: r.latest)
    }

    /// Tag, für den der nächste Wecker gilt: vor 9 Uhr heute, danach morgen
    func targetDay(_ now: Date = Date()) -> String {
        let h = Calendar.current.component(.hour, from: now)
        return Self.iso(h < 9 ? now : now.addingTimeInterval(86400))
    }

    /// Tage für Wecker + Widget (aus dem eigenen Stundenplan)
    func wakeDays() -> [WakeDay] {
        guard range.count == 2 else { return [] }
        var out: [WakeDay] = []
        var d = Date()
        for _ in 0..<9 {
            let iso = Self.iso(d)
            if let p = plan(for: iso) {
                let wd = Calendar.current.component(.weekday, from: d)
                let label = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"][wd - 1]
                out.append(WakeDay(date: iso, free: p.free, wake: p.wake, label: p.free && (wd == 1 || wd == 7) ? "Wochenende" : label, period: p.period, subject: p.subject))
            }
            d = d.addingTimeInterval(86400)
        }
        return out
    }

    /// Unterricht für die Startseite: heute (solange noch Stunden kommen), sonst der nächste Schultag
    func upcomingDay() -> (label: String, lessons: [SchoolLesson])? {
        let now = Date(), today = Self.iso(now)
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let time = f.string(from: now)
        let todays = lessons.filter { $0.date == today }
        if todays.contains(where: { $0.end > time }) { return ("Heute", todays) }
        guard let next = lessons.first(where: { $0.date > today }) else { return nil }
        return (dayTitle(next.date), lessons.filter { $0.date == next.date })
    }

    // MARK: Kurzbefehl

    struct ShortcutRun: Codable { let at: Date; let value: String; let note: String; let fresh: Bool }
    @Published private(set) var lastShortcut: ShortcutRun? = Store.load(ShortcutRun.self, "shortcut.json")

    /// Für den Kurzbefehl: frischen Stundenplan holen (ohne PC) und die Weckzeit liefern – leer, wenn keine Schule ist
    func shortcutWake(record: Bool = true) async -> (value: String, note: String) {
        let fresh = await refresh()
        let day = targetDay()
        var value = "", note: String
        if let own = Alarms.shared.overrides[day] {
            value = own == Alarms.off ? "" : own
            note = own == Alarms.off ? "\(dayTitle(day)): von dir auf „kein Wecker“ gestellt" : "\(dayTitle(day)): deine eigene Weckzeit \(own)"
        } else if let p = plan(for: day) {
            if p.free { note = "\(dayTitle(day)): keine Schule" }
            else {
                value = p.wake ?? ""
                note = "\(dayTitle(day)): \(p.period.map { "\($0). Stunde" } ?? "Schule")\(p.subject.map { " \($0)" } ?? "") → Wecker \(value)"
            }
        } else {
            note = login == nil ? "WebUntis nicht verbunden" : "Stundenplan für \(dayTitle(day)) fehlt"
        }
        if !fresh, login != nil { note += " (letzter Stand, WebUntis gerade nicht erreichbar)" }
        if record {
            let run = ShortcutRun(at: Date(), value: value, note: note, fresh: fresh)
            lastShortcut = run
            Store.save(run, "shortcut.json")
        }
        return (value, note)
    }

    // MARK: Hintergrund

    static let refreshTask = "hub.school.refresh"

    static func scheduleBackground() {
        let r = BGAppRefreshTaskRequest(identifier: refreshTask)
        r.earliestBeginDate = Date().addingTimeInterval(60 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
}

// MARK: - Kurzbefehl-Aktion

struct WakeTimeIntent: AppIntent {
    static var title: LocalizedStringResource = "Weckzeit holen"
    static var description = IntentDescription("Holt den Stundenplan direkt von WebUntis (ohne PC) und gibt die Weckzeit für den nächsten Morgen zurück (z. B. 07:25). Leer, wenn keine Schule ist.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let r = await School.shared.shortcutWake()
        await Alarms.shared.refreshFromSchool()
        return .result(value: r.value)
    }
}

struct HubShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WakeLightIntent(),
                    phrases: ["Aufstehlicht von \(.applicationName)", "\(.applicationName) Aufstehlicht prüfen"],
                    shortTitle: "Aufstehlicht prüfen",
                    systemImageName: "sun.horizon.fill")
        AppShortcut(intent: WakeTimeIntent(),
                    phrases: ["Weckzeit von \(.applicationName)", "\(.applicationName) Weckzeit holen"],
                    shortTitle: "Weckzeit holen",
                    systemImageName: "alarm")
    }
}
