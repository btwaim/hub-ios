import SwiftUI
import VisionKit
import PhotosUI
import CoreImage

// MARK: - Wecker-Seite

struct AlarmView: View {
    @EnvironmentObject var alarms: Alarms
    @ObservedObject private var school = School.shared
    @Environment(\.dismiss) private var dismiss
    @State private var connectOpen = false
    @State private var guideOpen = false
    @State private var checking = false
    @State private var checkResult: String?
    @State private var customDay: WakeDay?
    @State private var customTime = Date()

    /// nächster Wecker mit deinen eigenen Zeiten; Schlafenszeiten nur, wenn er aus dem Stundenplan kommt
    private var next: (day: WakeDay, at: Date, plan: WakePlan?)? {
        guard let n = alarms.next else { return nil }
        return (n.day, n.at, alarms.overrides[n.day.date] == nil ? school.plan(for: n.day.date) : nil)
    }

    var body: some View {
        NavigationStack {
            List {
                Section { hero }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                Section {
                    if school.connected {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(school.person ?? "Verbunden").font(.body.weight(.semibold))
                                Text(fetchedText).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if school.loading { ProgressView() }
                        }
                        if let e = school.lastError { Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange) }
                        Button { Task { await alarms.refresh() } } label: { Label("Jetzt neu abrufen", systemImage: "arrow.clockwise") }
                        Button(role: .destructive) { school.disconnect() } label: { Label("WebUntis trennen", systemImage: "xmark.circle") }
                    } else {
                        Button { connectOpen = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "qrcode.viewfinder").font(.title2).foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("WebUntis verbinden").font(.body.weight(.semibold))
                                    Text("Einmal den QR-Code scannen – danach ohne PC").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: { Text("Stundenplan direkt") } footer: {
                    Text(school.connected ? "Die App holt den Stundenplan selbst von WebUntis – auch wenn der PC aus ist. Fällt die 1. Stunde aus, rutscht die Weckzeit automatisch nach hinten."
                                          : "Ohne Verbindung kommen die Weckzeiten nur vom Hub am PC.")
                }

                Section {
                    Toggle(isOn: $alarms.enabled) { Label("Wecker nach Stundenplan", systemImage: "alarm.fill") }
                    Toggle(isOn: $alarms.gentle) { Label("Hub-Weckton (melodisch, wird lauter)", systemImage: "music.note") }
                    if alarms.gentle {
                        Toggle(isOn: $alarms.lead) { Label("3 Min sanfter Vorlauf", systemImage: "chart.line.uptrend.xyaxis") }
                    }
                    Button { Task { await alarms.testAlarm() } } label: { Label("Testwecker in 1 Minute", systemImage: "alarm.waves.left.and.right") }
                    if !alarms.status.isEmpty { Label(alarms.status, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Wecker") } footer: {
                    Text(alarms.gentle && alarms.lead
                         ? "Der Ton beginnt 3 Minuten vor deiner Weckzeit fast unhörbar und ist zur Weckzeit laut – so wirst du sanft aus dem Schlaf geholt. Melodie mit 105 BPM, Glocken-Klang um 1,3–2,6 kHz, in der lauten Phase kommt ein tiefer Ton um 520 Hz dazu (weckt am zuverlässigsten). Alten Health-/Uhr-Wecker ausschalten, damit nichts doppelt klingelt."
                         : "Hub stellt echte iPhone-Wecker – sie klingeln auch, wenn der PC aus und die App zu ist. Alten Health-/Uhr-Wecker ausschalten, damit nichts doppelt klingelt.")
                }

                Section {
                    if alarms.knownLamps.isEmpty {
                        Label("Noch keine Lampen – einmal die App öffnen, während der PC an ist", systemImage: "lightbulb.slash").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(alarms.knownLamps, id: \.id) { l in
                        let on = alarms.activeLamps.contains(l)
                        Button { alarms.toggleLamp(l) } label: {
                            HStack {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Color.yellow : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(l.name + (l.mine == true ? " (deine)" : "")).font(.body)
                                    Text(l.ip).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Picker("Licht startet", selection: $alarms.lightLead) {
                        Text("10 Min vorher").tag(10)
                        Text("20 Min").tag(20)
                        Text("30 Min").tag(30)
                    }
                    Picker("Geht aus", selection: $alarms.lightOff) {
                        Text("5 Min nach dem Wecker").tag(5)
                        Text("10 Min").tag(10)
                        Text("15 Min").tag(15)
                    }
                    HStack(spacing: 10) {
                        Button { Task { await alarms.testLight(true) } } label: { Label("Aufwachen testen", systemImage: "sunrise.fill") }
                            .buttonStyle(.bordered).tint(.yellow)
                        Button { Task { await alarms.testLight(false) } } label: { Label("Aus", systemImage: "lightbulb.slash") }
                            .buttonStyle(.bordered)
                    }
                    if let r = alarms.lightTestResult { Text(r).font(.footnote).foregroundStyle(.secondary) }
                    lightStatus
                    Button { guideOpen = true } label: { Label("Automationen einrichten – Schritt für Schritt", systemImage: "list.number") }
                } header: { Text("Aufstehlicht (WiZ „Aufwachen“)") } footer: {
                    Text("Hub schaltet deine WiZ-Lampe selbst: \(alarms.lightLead) Min vor dem Wecker „Aufwachen“ an (dimmt ca. 30 Min langsam von dunkel-lila bis hell), \(alarms.lightOff) Min nach dem Wecker wieder aus. Dafür braucht es Automationen um \(alarms.lightAutomationTimes.joined(separator: ", ")) und \(alarms.lightOffTimes.joined(separator: ", ")) – jeweils nur die Aktion „Aufstehlicht“ von Hub.")
                }

                Section {
                    ForEach(alarms.days) { d in dayRow(d) }
                    if alarms.days.isEmpty { Text("Noch keine Daten – WebUntis verbinden oder Hub am PC öffnen.").font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Nächste Tage") } footer: {
                    Text("Tippe auf einen Tag, wenn Untis es nicht weiß – z. B. erst zur 2. Stunde oder frei. Dann klingelt es zu deiner Zeit oder gar nicht. Das Aufstehlicht schaltet nur zu den drei normalen Zeiten.")
                }
            }
            .navigationTitle("Wecker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fertig") { dismiss() } } }
            .refreshable { await alarms.refresh() }
            .sheet(isPresented: $connectOpen) { UntisConnectSheet() }
            .sheet(isPresented: $guideOpen) { ShortcutGuide() }
            .sheet(item: $customDay) { d in customSheet(d) }
        }
    }

    /// eigene Uhrzeit für einen Tag
    private func customSheet(_ d: WakeDay) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(dayTitle(d.date)).font(.title2.bold())
                DatePicker("Weckzeit", selection: $customTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel).labelsHidden()
                Button {
                    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
                    alarms.setOverride(d.date, f.string(from: customTime))
                    customDay = nil
                } label: { Label("Wecker stellen", systemImage: "alarm.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
            }
            .padding(24)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Abbrechen") { customDay = nil } } }
        }
        .presentationDetents([.medium])
    }

    private var fetchedText: String {
        guard let f = school.lastFetch else { return "noch nicht abgerufen" }
        return "Stand: " + f.formatted(.relative(presentation: .named))
    }

    private var hero: some View {
        let n = next
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "alarm.fill")
                Text(n.map { dayTitle($0.day.date) } ?? "Nächster Wecker").textCase(.uppercase)
                Spacer()
                Text(alarms.enabled ? "AN" : "AUS").font(.caption2.weight(.heavy))
                    .padding(.horizontal, 8).padding(.vertical, 3).background(.white.opacity(0.2), in: Capsule())
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.85))
            if let n {
                Text(n.at, format: .dateTime.hour().minute())
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .shadow(color: .black.opacity(0.25), radius: 10)
                Text(alarms.overrides[n.day.date] != nil ? "Deine eigene Weckzeit"
                     : [n.day.period.map { "\($0). Stunde" }, n.day.subject].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline)
                if let off = n.plan?.off, let latest = n.plan?.latest {
                    Label("Offline \(off) · spätestens \(latest) schlafen", systemImage: "moon.stars.fill").font(.subheadline).foregroundStyle(.white.opacity(0.85))
                }
            } else {
                Text(school.connected ? "Keine Schule in Sicht" : "–")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text(school.connected ? "Ausschlafen 😴" : "Verbinde WebUntis, dann rechnet die App selbst.").font(.subheadline).foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 1, green: 0.55, blue: 0.2), Color(red: 0.62, green: 0.3, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .padding(.vertical, 4)
    }

    @ViewBuilder private var lightStatus: some View {
        if let s = alarms.lastLight {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: s.on ? "lightbulb.max.fill" : "lightbulb")
                    .foregroundStyle(s.on ? Color.yellow : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zuletzt geprüft: \(s.at.formatted(date: .abbreviated, time: .shortened))").font(.subheadline.weight(.semibold))
                    Text(s.note).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Label("Der Kurzbefehl hat noch nie nachgefragt", systemImage: "clock.badge.questionmark").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func dayRow(_ d: WakeDay) -> some View {
        let own = alarms.overrides[d.date]
        return Menu {
            Button { alarms.setOverride(d.date, nil) } label: {
                Label("Automatisch (Untis)", systemImage: own == nil ? "checkmark" : "calendar")
            }
            Section("Erst später") {
                ForEach(Alarms.presets, id: \.time) { p in
                    Button { alarms.setOverride(d.date, p.time) } label: {
                        Label("\(p.label) · \(p.time)", systemImage: own == p.time ? "checkmark" : "clock")
                    }
                }
                Button {
                    customTime = d.wakeDate ?? Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
                    customDay = d
                } label: { Label("Eigene Uhrzeit …", systemImage: "slider.horizontal.3") }
            }
            Button(role: .destructive) { alarms.setOverride(d.date, Alarms.off) } label: {
                Label("Kein Wecker (frei)", systemImage: own == Alarms.off ? "checkmark" : "bed.double.fill")
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(dayTitle(d.date)).font(.body.weight(.semibold))
                        if own != nil {
                            Text("EIGENE").font(.caption2.weight(.heavy)).foregroundStyle(.orange)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(own == Alarms.off ? "kein Wecker · von dir" : d.free ? "frei · ausschlafen"
                         : own != nil ? (d.period.map { "wie \($0). Stunde" } ?? "deine Zeit")
                         : [d.period.map { "\($0). Stunde" }, d.subject].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if d.free { Image(systemName: "bed.double.fill").foregroundStyle(.secondary) }
                else {
                    Text(d.wake ?? "").font(.title3.monospacedDigit().weight(.bold))
                        .foregroundStyle(own != nil ? Color.orange : d.period == 1 ? Color.primary : Color.green)
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

// MARK: - WebUntis verbinden (QR-Code)

struct UntisConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var school = School.shared
    @State private var photo: PhotosPickerItem?
    @State private var text = ""
    @State private var working = false
    @State private var message: String?
    @State private var scanning = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Am PC (oder im Browser) WebUntis öffnen → oben rechts auf dein **Profil** → **Freigaben** → bei „Zugriff über Untis Mobile“ auf **Anzeigen**. Den QR-Code dann hier scannen.")
                        .font(.subheadline)
                    ZStack {
                        if scanning && DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                            QRScanner { found in Task { await connect(found) } }
                        } else {
                            Color.white.opacity(0.06)
                            Image(systemName: "qrcode.viewfinder").font(.system(size: 60)).foregroundStyle(.secondary)
                        }
                        if working { Color.black.opacity(0.5); ProgressView().controlSize(.large) }
                    }
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                    HStack(spacing: 10) {
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label("Aus Foto/Screenshot", systemImage: "photo").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    HStack {
                        TextField("oder untis://setschool… einfügen", text: $text)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Button("OK") { Task { await connect(text) } }.buttonStyle(.borderedProminent).disabled(text.isEmpty)
                    }
                    if let m = message { Label(m, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange) }
                    Text("Der geheime Schlüssel bleibt nur im Schlüsselbund dieses iPhones. Damit erzeugt die App – wie die Untis-App – jede halbe Minute einen Einmal-Code.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("WebUntis verbinden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Abbrechen") { dismiss() } } }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let code = Self.qr(in: data) { await connect(code) }
                    else { message = "Im Bild wurde kein QR-Code gefunden" }
                }
            }
        }
    }

    private func connect(_ code: String) async {
        guard !working else { return }
        working = true
        scanning = false
        message = nil
        let ok = await school.connect(code)
        working = false
        if ok {
            await Alarms.shared.refreshFromSchool()
            dismiss()
        } else {
            message = school.lastError ?? "Verbinden hat nicht geklappt"
            scanning = true
        }
    }

    static func qr(in data: Data) -> String? {
        guard let img = CIImage(data: data),
              let det = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        return det.features(in: img).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first { $0.lowercased().hasPrefix("untis") }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    var onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        DispatchQueue.main.async { try? vc.startScanning() }
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) { vc.stopScanning() }
    func makeCoordinator() -> Coordinator { Coordinator(onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        private var done = false
        init(_ f: @escaping (String) -> Void) { onFound = f }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let b) = item, let v = b.payloadStringValue, v.lowercased().hasPrefix("untis"), !done {
                    done = true
                    onFound(v)
                }
            }
        }
    }
}

// MARK: - Anleitung Kurzbefehl

struct ShortcutGuide: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @ObservedObject private var alarms = Alarms.shared

    private var steps: [(String, String, String)] {
        let all = (alarms.lightAutomationTimes + alarms.lightOffTimes).map { "**\($0)**" }
        return [
        ("1", "Erst testen", "Hier in Hub → **Wecker** → **Aufwachen testen**. Beim ersten Mal fragt iOS nach **Lokales Netzwerk** → **Erlauben**. Die Lampe muss angehen (WiZ-App: Einstellungen → **Lokale Kommunikation** an)."),
        ("2", "Automation anlegen", "Kurzbefehle-App → unten **Automation** → oben **+** → **Tageszeit**."),
        ("3", "Uhrzeit", "Uhrzeit \(all.first ?? "") einstellen, **Täglich**, dann **Sofort ausführen** wählen → **Weiter**."),
        ("4", "Nur eine Aktion", "**Neuer leerer Kurzbefehl** → in der Suche **Aufstehlicht** eintippen → die Aktion von **Hub** antippen → **Fertig**. Mehr braucht es nicht: Hub entscheidet selbst, ob gerade an, aus oder nichts."),
        ("5", "Für alle Zeiten", "Das Gleiche für \(all.dropFirst().joined(separator: ", ")). Die ersten drei schalten \(alarms.lightLead) Min vor dem Wecker an, die anderen \(alarms.lightOff) Min nach dem Wecker aus."),
        ("6", "Alte Automation aus", "Deine alte Automation „Wenn Wecker klingelt → WiZ“ ausschalten und den alten Health-/Uhr-Wecker auch – jetzt weckt Hub."),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(steps, id: \.0) { s in
                        HStack(alignment: .top, spacing: 14) {
                            Text(s.0).font(.headline.monospacedDigit()).frame(width: 30, height: 30)
                                .background(Color.purple, in: Circle()).foregroundStyle(.white)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.1).font(.headline)
                                Text(.init(s.2)).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("So prüfst du, ob es klappt", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
                        Text(.init("• **Aufwachen testen** / **Aus** in Hub → Wecker schalten die Lampe sofort.\n• Unter „Zuletzt geprüft“ steht jeden Morgen, wann die Automation lief und was sie gemacht hat (z. B. „Wecker 06:25 → Aufwachen an“).\n• **Testwecker in 1 Minute** spielt den sanft lauter werdenden Ton."))
                            .font(.subheadline)
                        Text("An freien Tagen passiert nichts. Fällt die 1. Stunde spontan aus, merkt Hub das beim Prüfen und schaltet erst vor dem späteren Wecker.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular.tint(.green.opacity(0.25)), in: .rect(cornerRadius: 20))
                    Button {
                        if let u = URL(string: "shortcuts://") { openURL(u) }
                    } label: { Label("Kurzbefehle-App öffnen", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(20)
            }
            .navigationTitle("Aufstehlicht automatisch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fertig") { dismiss() } } }
        }
    }
}
