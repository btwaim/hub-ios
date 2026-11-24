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

    private var next: (plan: WakePlan, at: Date)? {
        guard school.connected else { return nil }
        for k in 0..<8 {
            let iso = isoDay(Date().addingTimeInterval(Double(k) * 86400))
            if let p = school.plan(for: iso), let at = p.wakeDate, at > Date() { return (p, at) }
        }
        return nil
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
                    Toggle(isOn: $alarms.gentle) { Label("Sanft lauter werdender Ton", systemImage: "speaker.wave.1.fill") }
                    Button { Task { await alarms.testAlarm() } } label: { Label("Testwecker in 1 Minute", systemImage: "alarm.waves.left.and.right") }
                    if !alarms.status.isEmpty { Label(alarms.status, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Wecker") } footer: {
                    Text("Hub stellt echte iPhone-Wecker – sie klingeln auch, wenn der PC aus und die App zu ist. Der Hub-Ton fängt ganz leise an und wird in einer Minute laut. Deinen alten Health-/Uhr-Wecker am besten ausschalten, damit nichts doppelt klingelt.")
                }

                Section {
                    lightStatus
                    Button { guideOpen = true } label: { Label("Kurzbefehl einrichten – Schritt für Schritt", systemImage: "list.number") }
                    Button {
                        alarms.startLightTest()
                        checkResult = "Test an: Starte jetzt in Kurzbefehle einmal „Hub Aufstehlicht“ – das Licht sollte angehen (10 Minuten lang)."
                    } label: { Label("Licht testen", systemImage: "lightbulb.max.fill") }
                    if let c = checkResult { Text(c).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Aufstehlicht (WiZ) · 10 Min vorher") } footer: {
                    Text("Ein Kurzbefehl fragt Hub kurz vor den möglichen Weckzeiten, ob gleich der Wecker klingelt – und schaltet dann dein WiZ-Aufstehlicht ein. Dabei holt Hub auch nochmal den frischen Stundenplan.")
                }

                Section("Nächste Tage") {
                    ForEach(alarms.days) { d in dayRow(d) }
                    if alarms.days.isEmpty { Text("Noch keine Daten – WebUntis verbinden oder Hub am PC öffnen.").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Wecker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fertig") { dismiss() } } }
            .refreshable { await alarms.refresh() }
            .sheet(isPresented: $connectOpen) { UntisConnectSheet() }
            .sheet(isPresented: $guideOpen) { ShortcutGuide() }
        }
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
                Text(n.map { dayTitle($0.plan.date) } ?? "Nächster Wecker").textCase(.uppercase)
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
                Text([n.plan.period.map { "\($0). Stunde" }, n.plan.subject].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline)
                if let off = n.plan.off, let latest = n.plan.latest {
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
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(dayTitle(d.date)).font(.body.weight(.semibold))
                Text(d.free ? "frei · ausschlafen" : [d.period.map { "\($0). Stunde" }, d.subject].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if d.free { Image(systemName: "bed.double.fill").foregroundStyle(.secondary) }
            else {
                Text(d.wake ?? "").font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(d.period == 1 ? Color.primary : Color.green)
            }
        }
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

    private let steps: [(String, String, String)] = [
        ("1", "Kurzbefehl anlegen", "Kurzbefehle-App öffnen → unten **Kurzbefehle** → oben **+**."),
        ("2", "Hub fragen", "In der Suche **Aufstehlicht prüfen** eintippen und die Aktion von **Hub** antippen."),
        ("3", "Wenn-Abfrage", "Suche **Wenn** → antippen. Bedingung: **Aufstehlicht** · **ist** · **wahr** (bzw. „Ja“)."),
        ("4", "WiZ einschalten", "In die **Wenn**-Klammer deine WiZ-Aktion für den **Aufstehen-Modus** ziehen – dieselbe wie in deinem bisherigen Kurzbefehl (oder **Kurzbefehl ausführen** → deinen WiZ-Kurzbefehl)."),
        ("5", "Namen geben", "Oben auf den Namen tippen → **Hub Aufstehlicht** → Fertig."),
        ("6", "Drei Automationen", "Unten **Automation** → **+** → **Tageszeit** → **06:15**, **Täglich** → **Sofort ausführen** → **Hub Aufstehlicht**. Das Gleiche nochmal für **07:15** und **08:20** (10 Minuten vor 06:25, 07:25 und 08:30)."),
        ("7", "Alte Automation aus", "Deine alte Automation „Wenn Wecker klingelt → WiZ“ ausschalten, und den alten Health-/Uhr-Wecker auch – jetzt weckt Hub."),
    ]

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
                        Text(.init("• In Hub → **Wecker** auf **Licht testen** tippen.\n• Dann in Kurzbefehle einmal auf **Hub Aufstehlicht** tippen → das WiZ-Licht geht an.\n• Hier unter „Zuletzt geprüft“ siehst du jeden Morgen, wann der Kurzbefehl gefragt hat und ob das Licht anging.\n• **Testwecker in 1 Minute** spielt den sanft lauter werdenden Ton."))
                            .font(.subheadline)
                        Text("Die Prüfung sagt nur „an“, wenn der Hub-Wecker in den nächsten 2–22 Minuten klingelt. An freien Tagen bleibt das Licht aus.")
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
            .navigationTitle("Aufstehlicht per Kurzbefehl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fertig") { dismiss() } } }
        }
    }
}
