import SwiftUI

/// Überschrift über einer Karte (Apple-Stil: fett, optional mit Pfeil)
struct SectionTitle: View {
    let text: String
    var action: (() -> Void)?
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.title3.bold())
            if action != nil { Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary) }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .padding(.top, 8)
    }
}

// MARK: - Start

struct HomeView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var alarms: Alarms
    @EnvironmentObject var hub: HubStore
    @EnvironmentObject var nav: Nav
    @ObservedObject private var school = School.shared
    @State private var showSettings = false

    @State private var showDL = false

    private var state: HubState? { library.hub }

    struct TTRow { let start: String; let subject: String; let room: String; let kind: String }

    /// Stundenplan: direkt von WebUntis (ohne PC), sonst vom Hub
    private var timetable: (label: String, rows: [TTRow])? {
        if school.connected, let d = school.upcomingDay(), !d.lessons.isEmpty {
            let rows: [TTRow] = d.lessons.map { TTRow(start: $0.start, subject: $0.subject, room: $0.room, kind: $0.kind) }
            return (d.label, rows)
        }
        if let s = state?.school, let l = s.lessons, !l.isEmpty {
            let rows: [TTRow] = l.map { TTRow(start: $0.start ?? "", subject: $0.subject ?? "–", room: $0.room ?? "", kind: $0.kind ?? "normal") }
            return (s.label ?? "Schule", rows)
        }
        return nil
    }

    /// nächste Weckzeit + Beschreibung (eigener Stundenplan zuerst, sonst vom Hub)
    private var nextWake: (at: Date, text: String)? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        if school.connected {
            for k in 0..<8 {
                let iso = f.string(from: Date().addingTimeInterval(Double(k) * 86400))
                if let p = school.plan(for: iso), let at = p.wakeDate, at > Date() {
                    var parts = [dayTitle(iso)]
                    if let n = p.period { parts.append("\(n). Stunde") }
                    if let s = p.subject { parts.append(s) }
                    return (at, parts.joined(separator: " · "))
                }
            }
        }
        for d in alarms.days {
            guard let at = d.wakeDate, at > Date() else { continue }
            var parts = [dayTitle(d.date)]
            if let n = d.period { parts.append("\(n). Stunde") }
            if let s = d.subject { parts.append(s) }
            return (at, parts.joined(separator: " · "))
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if player.current != nil { nowPlaying }
                    quick
                    if let t = timetable { schoolCard(t.label, t.rows) }
                    wakeCard
                    if let ex = state?.nextExam { examCard(ex) }
                    if let ev = state?.events, !ev.isEmpty { eventsCard(ev) }
                    if let w = state?.watch, !w.isEmpty { watchRow(w) }
                    if let g = state?.gta { gtaCard(g) }
                    status
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .background(alignment: .top) {
                ZStack {
                    RadialGradient(colors: [Color.purple.opacity(0.45), .clear], center: .topLeading, startRadius: 10, endRadius: 420)
                    RadialGradient(colors: [Color.pink.opacity(0.18), .clear], center: .topTrailing, startRadius: 10, endRadius: 360)
                }
                .frame(height: 520).ignoresSafeArea()
            }
            .refreshable {
                await library.refresh()
                await hub.refresh()
                await alarms.refresh()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                }
            }
            .sheet(isPresented: $nav.showAlarms) { AlarmView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showDL) { DownloaderView() }
            .fullScreenCover(isPresented: $nav.showMap) { GTAMapScreen() }
        }
    }

    // MARK: Teile

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase)
                .environment(\.locale, Locale(identifier: "de_DE"))
            Text(state?.greeting ?? "Hey").font(.system(size: 34, weight: .heavy, design: .rounded))
        }
        .padding(.top, 6)
    }

    private var nowPlaying: some View {
        Button { nav.showPlayer = true } label: {
            HStack(spacing: 14) {
                HDCover(track: player.current, corner: 12).frame(width: 62, height: 62)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        PlayingBars(playing: player.isPlaying)
                        Text(player.isPlaying ? "LÄUFT" : "PAUSIERT").font(.caption2.weight(.heavy)).foregroundStyle(.white.opacity(0.75))
                    }
                    Text(player.current?.title ?? "").font(.headline).lineLimit(1)
                    Text(player.current?.artist ?? "").font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
            }
            .foregroundStyle(.white)
            .padding(12)
            .background {
                ZStack {
                    CoverBackdrop(track: player.current)
                    Color.black.opacity(0.15)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var quick: some View {
        HStack(spacing: 10) {
            quickButton("GTA-Karte", "map.fill", [.pink, .orange]) { nav.showMap = true }
            quickButton("Downloader", "arrow.down.circle.fill", [.purple, .blue]) { showDL = true }
            quickButton("Wecker", "alarm.fill", [.orange, .yellow]) { nav.showAlarms = true }
        }
    }

    private func quickButton(_ title: String, _ icon: String, _ colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .shadow(color: colors[0].opacity(0.45), radius: 8, y: 4)
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }

    private func schoolCard(_ label: String, _ rows: [TTRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Stundenplan · \(label)") { nav.showAlarms = true }
            Card(padding: 14) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, l in
                        let off = l.kind == "cancel" || l.kind == "movedAway"
                        HStack(spacing: 12) {
                            Text(l.start).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                            Capsule().fill(kindColor(l.kind)).frame(width: 4, height: 28)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(l.subject).font(.body.weight(.semibold)).strikethrough(off).foregroundStyle(off ? .secondary : .primary)
                                if !l.room.isEmpty { Text(l.room).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if l.kind != "normal" { tag(l.kind) }
                        }
                        .padding(.vertical, 6)
                        if i < rows.count - 1 { Divider().padding(.leading, 60) }
                    }
                }
            }
        }
    }

    private func kindColor(_ k: String) -> Color {
        switch k {
        case "cancel", "movedAway", "exam": return .red
        case "movedIn", "extra": return .green
        case "room": return .yellow
        case "normal": return .blue.opacity(0.7)
        default: return .orange
        }
    }

    private func tag(_ kind: String) -> some View {
        let (t, c): (String, Color) = switch kind {
        case "cancel": ("Entfall", .red)
        case "movedAway": ("verlegt", .orange)
        case "movedIn", "extra": ("extra", .green)
        case "exam": ("Arbeit", .red)
        case "room": ("Raum", .yellow)
        default: ("Vertretung", .orange)
        }
        return Text(t).font(.caption2.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(c.opacity(0.2), in: Capsule()).foregroundStyle(c)
    }

    private var wakeCard: some View {
        let next = nextWake
        return Button { nav.showAlarms = true } label: {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "alarm.fill").font(.title2).foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    if let n = next {
                        Text(n.at, format: .dateTime.hour().minute()).font(.system(size: 30, weight: .heavy, design: .rounded))
                        Text(n.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("Kein Wecker").font(.title3.bold())
                        Text(school.connected ? "Keine Schule in Sicht" : "WebUntis verbinden für Weckzeiten ohne PC").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(alarms.mode == .health ? "Health" : "Hub").font(.caption2.weight(.heavy))
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Color.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }

    private func examCard(_ e: HubState.Exam) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text.fill").font(.title3).foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("NÄCHSTE ARBEIT" + (e.when.map { " · \($0.uppercased())" } ?? "")).font(.caption2.weight(.heavy)).foregroundStyle(.red)
                Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(.regular.tint(.red.opacity(0.12)), in: .rect(cornerRadius: 22))
    }

    private func eventsCard(_ ev: [HubState.Ev]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Termine") { nav.tab = 2 }
            Card(padding: 14) {
                VStack(spacing: 10) {
                    ForEach(Array(ev.prefix(4).enumerated()), id: \.offset) { _, e in
                        let st = eventStyle(e.type ?? "")
                        HStack(spacing: 12) {
                            Image(systemName: st.icon).font(.subheadline.weight(.semibold)).foregroundStyle(st.color)
                                .frame(width: 32, height: 32).background(st.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Text(e.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text(e.when ?? "").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func watchRow(_ w: [HubState.Show]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Weiterschauen") { nav.tab = 3 }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(w) { s in
                        VStack(alignment: .leading, spacing: 6) {
                            RemoteImage(url: s.image, icon: "film")
                                .frame(width: 112, height: 166)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    if s.newEp == true {
                                        Text("NEU").font(.system(size: 10, weight: .heavy)).padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(Color.purple, in: Capsule()).padding(6)
                                            .shadow(color: .purple, radius: 6)
                                    }
                                }
                                .overlay(alignment: .bottom) {
                                    if let p = s.pct {
                                        GeometryReader { g in
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(.black.opacity(0.4))
                                                Capsule().fill(Color.purple).frame(width: g.size.width * min(1, p / 100))
                                            }
                                        }
                                        .frame(height: 4).padding(8)
                                    }
                                }
                                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                            Text(s.title).font(.caption.weight(.semibold)).lineLimit(1).frame(width: 112, alignment: .leading)
                            if let pr = s.progress { Text(pr).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 112, alignment: .leading) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    private func gtaCard(_ g: String) -> some View {
        Button { nav.showMap = true } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.55), Color(red: 1, green: 0.62, blue: 0.25), Color(red: 0.35, green: 0.15, blue: 0.6)],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                Image(systemName: "sun.horizon.fill").font(.system(size: 120)).foregroundStyle(.white.opacity(0.18))
                    .offset(x: 200, y: -10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GTA VI").font(.caption.weight(.heavy)).opacity(0.85)
                    Text(g).font(.title2.weight(.heavy))
                    Label("Leonida-Karte öffnen", systemImage: "map.fill").font(.subheadline.weight(.semibold)).opacity(0.9)
                }
                .foregroundStyle(.white)
                .padding(18)
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle().fill(library.pcOnline ? Color.green : Color.gray).frame(width: 7, height: 7)
            Text(library.pcOnline ? "Mit dem Hub verbunden" : "Ohne PC – letzter Stand")
            if hub.queued > 0 { Text("· \(hub.queued) wartet") }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }
}

// MARK: - Kalender

struct CalendarView: View {
    @EnvironmentObject var hub: HubStore
    @State private var adding = false

    private var groups: [(date: String, items: [HubData.Event])] {
        let ev = hub.data?.events ?? []
        var order: [String] = []
        var map: [String: [HubData.Event]] = [:]
        for e in ev {
            if map[e.date] == nil { order.append(e.date) }
            map[e.date, default: []].append(e)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    weekStrip
                    ForEach(groups, id: \.date) { g in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(dayTitle(g.date)).font(.title3.bold())
                                Text(shortDate(g.date)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            VStack(spacing: 8) {
                                ForEach(g.items, id: \.self) { e in row(e) }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView("Keine Termine", systemImage: "calendar", description: Text("Tippe auf +, um etwas einzutragen."))
                }
            }
            .navigationTitle("Kalender")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await hub.refresh() }
            .sheet(isPresented: $adding) { AddEventSheet().presentationDetents([.height(280)]) }
        }
    }

    /// die nächsten 14 Tage mit Punkten für Termine
    private var weekStrip: some View {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let days = (0..<14).map { Date().addingTimeInterval(Double($0) * 86400) }
        let has = Set((hub.data?.events ?? []).map(\.date))
        let exams = Set((hub.data?.events ?? []).filter { eventStyle($0.type).color == .red }.map(\.date))
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { d in
                    let iso = f.string(from: d)
                    let today = Calendar.current.isDateInToday(d)
                    VStack(spacing: 5) {
                        Text(d, format: .dateTime.weekday(.abbreviated)).font(.caption2.weight(.semibold)).foregroundStyle(today ? Color.white : Color.secondary)
                            .environment(\.locale, Locale(identifier: "de_DE"))
                        Text(d, format: .dateTime.day()).font(.headline.monospacedDigit())
                        Circle().fill(exams.contains(iso) ? Color.red : has.contains(iso) ? Color.purple : .clear).frame(width: 6, height: 6)
                    }
                    .frame(width: 46, height: 70)
                    .background(today ? AnyShapeStyle(Color.purple.gradient) : AnyShapeStyle(Color.white.opacity(0.06)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .scrollClipDisabled()
    }

    private func shortDate(_ iso: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: iso) else { return "" }
        let o = DateFormatter(); o.locale = Locale(identifier: "de_DE"); o.dateFormat = "d. MMM"
        return o.string(from: d)
    }

    private func row(_ e: HubData.Event) -> some View {
        let st = eventStyle(e.type)
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(st.color).frame(width: 4)
            Image(systemName: st.icon).font(.body.weight(.semibold)).foregroundStyle(st.color)
                .frame(width: 36, height: 36)
                .background(st.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text([e.time, e.mine == true ? "eigener Termin" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(st.color == .red ? Color.red.opacity(0.1) : Color.clear), in: .rect(cornerRadius: 18))
        .contextMenu {
            if e.mine == true, let id = e.id {
                Button(role: .destructive) {
                    hub.act(["type": "cal-del", "id": id]) { d in d.events.removeAll { $0.id == id } }
                } label: { Label("Löschen", systemImage: "trash") }
            }
        }
    }
}

struct AddEventSheet: View {
    @EnvironmentObject var hub: HubStore
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Termin eintragen").font(.title3.bold())
            TextField("z. B. Mathe-Arbeit am Dienstag", text: $text)
                .padding(14)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(add)
            Text(library.pcOnline ? "Der Hub erkennt Datum, Uhrzeit und Art (Arbeit, Hausaufgabe …) selbst."
                                  : "Ohne PC: wird eingetragen, sobald der Hub wieder erreichbar ist.")
                .font(.footnote).foregroundStyle(.secondary)
            Button(action: add) {
                Text("Eintragen").font(.headline).frame(maxWidth: .infinity).frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(24)
        .onAppear { focused = true }
    }

    private func add() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        hub.act(["type": "cal-add", "text": t])
        dismiss()
    }
}

// MARK: - Watchlist

struct WatchlistView: View {
    @EnvironmentObject var hub: HubStore
    @AppStorage("watchFilter") private var filter = "aktiv"
    @State private var open: IDBox?
    private let cols = [GridItem(.adaptive(minimum: 104), spacing: 14)]

    private var items: [HubData.Media] {
        let all = hub.data?.media ?? []
        return filter == "alle" ? all : all.filter { $0.status == filter }
    }
    private var hero: HubData.Media? {
        (hub.data?.media ?? []).first { $0.status == "aktiv" && ($0.newEp ?? 0) > 0 } ?? (hub.data?.media ?? []).first { $0.status == "aktiv" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let h = hero, filter == "aktiv" { heroCard(h) }
                    Picker("Status", selection: $filter) {
                        Text("Läuft").tag("aktiv")
                        Text("Geplant").tag("geplant")
                        Text("Fertig").tag("fertig")
                        Text("Alle").tag("alle")
                    }
                    .pickerStyle(.segmented)
                    LazyVGrid(columns: cols, spacing: 18) {
                        ForEach(items, id: \.id) { m in
                            Button { open = IDBox(id: m.id) } label: { MediaCard(m: m) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { plus(m, 1) } label: { Label("Folge gesehen", systemImage: "plus") }
                                    Button { plus(m, -1) } label: { Label("−1", systemImage: "minus") }
                                }
                        }
                    }
                }
                .padding(16)
            }
            .overlay {
                if items.isEmpty { ContentUnavailableView("Nichts hier", systemImage: "play.tv", description: Text("Öffne die App, während der PC an ist.")) }
            }
            .navigationTitle("Watchlist")
            .refreshable { await hub.refresh() }
            .sheet(item: $open) { box in
                MediaSheet(id: box.id).presentationDetents([.height(330)]).presentationCornerRadius(32)
            }
        }
    }

    private func heroCard(_ m: HubData.Media) -> some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: m.image, icon: "film").blur(radius: 24).opacity(0.85)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 14) {
                RemoteImage(url: m.image, icon: "film")
                    .frame(width: 92, height: 136)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
                VStack(alignment: .leading, spacing: 4) {
                    if let n = m.newEp, n > 0 {
                        Text("\(n) NEUE FOLGE\(n == 1 ? "" : "N")").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(Color.purple, in: Capsule())
                    }
                    Text(m.title).font(.title3.bold()).lineLimit(2)
                    Text(m.progress).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                    Button { plus(m, 1) } label: {
                        Label("Folge gesehen", systemImage: "plus").font(.subheadline.weight(.bold)).padding(.horizontal, 14).frame(height: 36)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.purple.opacity(0.6)).interactive(), in: .capsule)
                    .padding(.top, 4)
                }
                .foregroundStyle(.white)
            }
            .padding(16)
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func plus(_ m: HubData.Media, _ d: Int) {
        hub.act(["type": d > 0 ? "media+1" : "media-1", "id": m.id]) { data in
            if let i = data.media.firstIndex(where: { $0.id == m.id }) { bumpLabel(&data.media[i], d) }
        }
    }
}

struct IDBox: Identifiable { let id: String }

struct MediaCard: View {
    let m: HubData.Media
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: m.image, icon: "film")
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let n = m.newEp, n > 0 {
                        Text("+\(n)").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.purple, in: Capsule()).padding(6)
                            .shadow(color: .purple, radius: 6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let p = m.pct {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.black.opacity(0.45))
                                Capsule().fill(Color.purple).frame(width: g.size.width * min(1, p / 100))
                            }
                        }
                        .frame(height: 4)
                        .padding(7)
                    }
                }
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            Text(m.title).font(.caption.weight(.semibold)).lineLimit(2)
            Text(m.progress).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct MediaSheet: View {
    let id: String
    @EnvironmentObject var hub: HubStore

    private var m: HubData.Media? { hub.data?.media.first { $0.id == id } }

    var body: some View {
        if let m {
            HStack(alignment: .top, spacing: 18) {
                RemoteImage(url: m.image, icon: "film")
                    .frame(width: 124, height: 184)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(m.title).font(.title3.bold()).lineLimit(3)
                    Text(m.progress).font(.headline).foregroundStyle(.purple).contentTransition(.numericText())
                    if let p = m.pct { ProgressView(value: min(1, p / 100)).tint(.purple) }
                    if let n = m.newEp, n > 0 { Label("\(n) neue Folge\(n == 1 ? "" : "n")", systemImage: "sparkles").font(.subheadline).foregroundStyle(.pink) }
                    Spacer(minLength: 8)
                    HStack(spacing: 10) {
                        Button { bump(-1) } label: { Image(systemName: "minus").font(.headline).frame(width: 44, height: 44) }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .circle)
                        Button { bump(1) } label: {
                            Label("Folge gesehen", systemImage: "plus").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(.purple.opacity(0.6)).interactive(), in: .capsule)
                    }
                    .sensoryFeedback(.increase, trigger: m.progress)
                }
            }
            .padding(24)
        }
    }

    private func bump(_ d: Int) {
        withAnimation {
            hub.act(["type": d > 0 ? "media+1" : "media-1", "id": id]) { data in
                if let i = data.media.firstIndex(where: { $0.id == id }) { bumpLabel(&data.media[i], d) }
            }
        }
    }
}

// MARK: - Gaming

struct GamingView: View {
    @EnvironmentObject var hub: HubStore
    @AppStorage("gameFilter") private var filter = "alle"

    private let status = ["spiele": "Spiele ich", "backlog": "Backlog", "durch": "Durchgespielt", "pausiert": "Pausiert"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let g = hub.data?.activeGame {
                        ActiveGameCard(game: g)
                        if !g.bosses.isEmpty { bosses(g) }
                    }
                    library
                }
                .padding(16)
            }
            .overlay {
                if (hub.data?.games ?? []).isEmpty { ContentUnavailableView("Keine Spiele", systemImage: "gamecontroller", description: Text("Spiele fügst du im Hub am PC hinzu.")) }
            }
            .navigationTitle("Gaming")
            .refreshable { await hub.refresh() }
        }
    }

    private func bosses(_ g: HubData.Game) -> some View {
        let done = g.bosses.filter(\.defeated).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bosse").font(.title3.bold())
                Spacer()
                Text("\(done) von \(g.bosses.count)").font(.subheadline.monospacedDigit().weight(.bold)).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(done), total: Double(max(g.bosses.count, 1))).tint(.orange)
            Card(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(g.bosses.enumerated()), id: \.element.id) { i, b in
                        HStack(spacing: 12) {
                            Button { toggle(g, b) } label: {
                                Image(systemName: b.defeated ? "checkmark.circle.fill" : "circle")
                                    .font(.title2).foregroundStyle(b.defeated ? Color.green : Color.secondary)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(b.name).font(.body.weight(b.id == g.bossId ? .bold : .regular)).strikethrough(b.defeated)
                                    .foregroundStyle(b.defeated ? .secondary : .primary)
                                if b.id == g.bossId && !b.defeated {
                                    Label("aktueller Boss", systemImage: "flame.fill").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            if b.deaths > 0 { Label("\(b.deaths)", systemImage: "skull.fill").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 10)
                        .background(b.id == g.bossId && !b.defeated ? Color.orange.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 14))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !b.defeated, b.id != g.bossId else { return }
                            hub.act(["type": "boss-active", "game": g.id, "boss": b.id]) { d in
                                if let i = d.games.firstIndex(where: { $0.id == g.id }) { d.games[i].bossId = b.id }
                            }
                        }
                        if i < g.bosses.count - 1 { Divider().padding(.leading, 50) }
                    }
                }
            }
            Text("Antippen = aktueller Boss · Kreis = besiegt").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func toggle(_ g: HubData.Game, _ b: HubData.Boss) {
        hub.act(["type": "boss", "game": g.id, "boss": b.id]) { d in
            guard let i = d.games.firstIndex(where: { $0.id == g.id }), let k = d.games[i].bosses.firstIndex(where: { $0.id == b.id }) else { return }
            d.games[i].bosses[k].defeated.toggle()
            if d.games[i].bosses[k].defeated && d.games[i].bossId == b.id {
                d.games[i].bossId = d.games[i].bosses.first { !$0.defeated }?.id
            }
        }
    }

    private var library: some View {
        let all = (hub.data?.games ?? []).filter { $0.id != hub.data?.active }
        let games = filter == "alle" ? all : all.filter { $0.status == filter }
        return VStack(alignment: .leading, spacing: 10) {
            if !all.isEmpty {
                Text("Bibliothek").font(.title3.bold()).padding(.top, 6)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["alle", "spiele", "backlog", "pausiert", "durch"], id: \.self) { k in
                            Button { withAnimation { filter = k } } label: {
                                Text(k == "alle" ? "Alle" : status[k] ?? k).font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(filter == k ? Color.purple : Color.white.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            ForEach(games, id: \.id) { g in
                HStack(spacing: 12) {
                    RemoteImage(url: g.image, icon: "gamecontroller")
                        .frame(width: 104, height: 49)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(g.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 8) {
                            if let s = g.status { Text(status[s] ?? s) }
                            if g.counts == true { Label("\(g.deaths)", systemImage: "skull.fill") }
                            if !g.bosses.isEmpty { Label("\(g.bosses.filter(\.defeated).count)/\(g.bosses.count)", systemImage: "flag.checkered") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        hub.act(["type": "game-active", "game": g.id]) { d in d.active = g.id }
                    } label: {
                        Image(systemName: "play.fill").font(.subheadline).frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                }
                .padding(8)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
        }
    }
}

struct ActiveGameCard: View {
    let game: HubData.Game
    @EnvironmentObject var hub: HubStore

    var body: some View {
        VStack(spacing: 0) {
            // Banner (Steam-Bild) oben
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: game.image, icon: "gamecontroller")
                    .frame(height: 150)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SPIELE GERADE").font(.caption2.weight(.heavy)).foregroundStyle(.white.opacity(0.7))
                    Text(game.name).font(.title2.weight(.heavy)).lineLimit(1)
                    if let b = game.currentBoss {
                        Label(b.name, systemImage: "flame.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(.white)
                .padding(16)
            }
            .frame(height: 150)
            // Tod-Zähler
            VStack(spacing: 10) {
                Text("\(game.shownDeaths)")
                    .font(.system(size: 76, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(game.shownDeaths)))
                    .shadow(color: .red.opacity(0.7), radius: 18)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: game.shownDeaths)
                Text(game.currentBoss != nil ? "Tode bei diesem Boss · \(game.deaths) gesamt" : "Tode gesamt")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.65))
                HStack(spacing: 14) {
                    Button { death(-1) } label: {
                        Image(systemName: "minus").font(.title2.weight(.bold)).frame(width: 60, height: 60)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                    Button { death(1) } label: {
                        Label("Tod", systemImage: "skull.fill").font(.title3.weight(.heavy)).frame(maxWidth: .infinity).frame(height: 60)
                    }
                    .glassEffect(.regular.tint(.red.opacity(0.65)).interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(weight: .heavy), trigger: game.deaths)
            }
            .padding(18)
        }
        .foregroundStyle(.white)
        .background {
            ZStack {
                RemoteImage(url: game.image, icon: "gamecontroller").blur(radius: 40).opacity(0.6)
                Color.black.opacity(0.55)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func death(_ d: Int) {
        guard d > 0 || game.shownDeaths > 0 else { return }
        hub.act(["type": "death", "d": d, "game": game.id]) { data in
            guard let i = data.games.firstIndex(where: { $0.id == game.id }) else { return }
            if let bid = data.games[i].currentBoss?.id, let k = data.games[i].bosses.firstIndex(where: { $0.id == bid }) {
                data.games[i].bosses[k].deaths += d
            }
            data.games[i].deaths += d
        }
    }
}
