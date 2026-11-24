import SwiftUI

// MARK: - Start

struct HomeView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var alarms: Alarms
    @EnvironmentObject var hub: HubStore
    @EnvironmentObject var nav: Nav
    @State private var showAlarms = false
    @State private var showSettings = false
    @State private var showMap = false
    @State private var showDL = false

    private var state: HubState? { library.hub }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if player.current != nil { nowPlaying }
                    quick
                    if let s = state?.school, let lessons = s.lessons, !lessons.isEmpty { school(s.label ?? "Schule", lessons) }
                    wake
                    if let ex = state?.nextExam { exam(ex) }
                    if let ev = state?.events, !ev.isEmpty { events(ev) }
                    if let w = state?.watch, !w.isEmpty { watch(w) }
                    if let g = state?.gta { gta(g) }
                    status
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(alignment: .top) {
                LinearGradient(colors: [Color.purple.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 360).ignoresSafeArea()
            }
            .refreshable {
                await library.refresh()
                await hub.refresh()
                await alarms.refresh()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showAlarms) { AlarmView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showDL) { DownloaderView() }
            .fullScreenCover(isPresented: $showMap) { GTAMapScreen() }
        }
    }

    /// Schnellzugriff: GTA-Karte, Downloader, Wecker
    private var quick: some View {
        HStack(spacing: 10) {
            quickButton("GTA-Karte", "map.fill", [.pink, .orange]) { showMap = true }
            quickButton("Downloader", "arrow.down.circle.fill", [.purple, .blue]) { showDL = true }
            quickButton("Wecker", "alarm.fill", [.orange, .yellow]) { showAlarms = true }
        }
    }

    private func quickButton(_ title: String, _ icon: String, _ colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .environment(\.locale, Locale(identifier: "de_DE"))
            Text(state?.greeting ?? "Hey").font(.largeTitle.bold())
        }
        .padding(.top, 8)
    }

    private var nowPlaying: some View {
        Button { nav.showPlayer = true } label: {
            Card(padding: 12) {
                HStack(spacing: 12) {
                    HDCover(track: player.current, corner: 12).frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.isPlaying ? "Läuft gerade" : "Pausiert").font(.caption.weight(.bold)).foregroundStyle(.purple)
                        Text(player.current?.title ?? "").font(.headline).lineLimit(1)
                        Text(player.current?.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func school(_ label: String, _ lessons: [HubState.Lesson]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(text: "Stundenplan · \(label)", icon: "graduationcap.fill", color: .blue)
                ForEach(Array(lessons.enumerated()), id: \.offset) { _, l in
                    let k = l.kind ?? "normal"
                    let off = k == "cancel" || k == "movedAway"
                    HStack(spacing: 10) {
                        Text(l.start ?? "").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                        Text(l.subject ?? "–").font(.body.weight(.semibold)).strikethrough(off).foregroundStyle(off ? .secondary : .primary)
                        if let r = l.room, !r.isEmpty { Text(r).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if k != "normal" { tag(k) }
                    }
                }
            }
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
        return Text(t).font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(c.opacity(0.22), in: Capsule()).foregroundStyle(c)
    }

    private var wake: some View {
        let next = alarms.days.compactMap { d in d.wakeDate.map { (d, $0) } }.first { $0.1 > Date() }
        return Button { showAlarms = true } label: {
            Card {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        CardTitle(text: "Wecker", icon: "alarm.fill", color: .orange)
                        if let n = next {
                            Text(n.1, format: .dateTime.hour().minute()).font(.system(size: 34, weight: .bold, design: .rounded))
                            Text([dayTitle(n.0.date), n.0.period.map { "\($0). Stunde" }, n.0.subject].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("Kein Wecker geplant").font(.headline)
                        }
                        if let s = state?.sleep { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func exam(_ e: HubState.Exam) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                CardTitle(text: "Nächste Arbeit" + (e.when.map { " · \($0)" } ?? ""), icon: "doc.text.fill", color: .red)
                Text(e.title).font(.headline).lineLimit(2)
            }
        }
    }

    private func events(_ ev: [HubState.Ev]) -> some View {
        Button { nav.tab = 2 } label: {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle(text: "Termine", icon: "calendar", color: .purple)
                    ForEach(Array(ev.prefix(4).enumerated()), id: \.offset) { _, e in
                        let st = eventStyle(e.type ?? "")
                        HStack(spacing: 10) {
                            Image(systemName: st.icon).foregroundStyle(st.color).frame(width: 22)
                            Text(e.title).lineLimit(1)
                            Spacer()
                            Text(e.when ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func watch(_ w: [HubState.Show]) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Button { nav.tab = 3 } label: { CardTitle(text: "Weiterschauen", icon: "play.tv.fill", color: .pink) }.buttonStyle(.plain)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(w) { s in
                            VStack(alignment: .leading, spacing: 4) {
                                RemoteImage(url: s.image, icon: "film")
                                    .frame(width: 92, height: 136)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(alignment: .topTrailing) {
                                        if s.newEp == true { Text("NEU").font(.system(size: 9, weight: .heavy)).padding(4).background(Color.purple, in: Capsule()).padding(5) }
                                    }
                                    .overlay(alignment: .bottom) {
                                        if let p = s.pct { ProgressView(value: min(1, p / 100)).tint(.purple).padding(6) }
                                    }
                                Text(s.title).font(.caption2.weight(.semibold)).lineLimit(1).frame(width: 92, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
    }

    private func gta(_ g: String) -> some View {
        Button { showMap = true } label: { gtaCard(g) }.buttonStyle(.plain)
    }

    private func gtaCard(_ g: String) -> some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    CardTitle(text: "GTA VI", icon: "sun.horizon.fill", color: .pink)
                    Text(g).font(.title3.bold())
                }
                Spacer()
                Image(systemName: "palm.tree.fill").font(.system(size: 34)).foregroundStyle(
                    LinearGradient(colors: [.pink, .orange], startPoint: .top, endPoint: .bottom))
            }
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle().fill(library.pcOnline ? Color.green : Color.gray).frame(width: 7, height: 7)
            Text(library.pcOnline ? "Mit dem Hub verbunden" : "Ohne PC – zeigt den letzten Stand")
            if hub.queued > 0 { Text("· \(hub.queued) wartet") }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
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
            List {
                ForEach(groups, id: \.date) { g in
                    Section(dayTitle(g.date)) {
                        ForEach(g.items, id: \.self) { e in
                            row(e)
                                .swipeActions {
                                    if e.mine == true, let id = e.id {
                                        Button(role: .destructive) {
                                            hub.act(["type": "cal-del", "id": id]) { d in d.events.removeAll { $0.id == id } }
                                        } label: { Label("Löschen", systemImage: "trash") }
                                    }
                                }
                        }
                    }
                }
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
            .sheet(isPresented: $adding) { AddEventSheet().presentationDetents([.height(260)]) }
        }
    }

    private func row(_ e: HubData.Event) -> some View {
        let st = eventStyle(e.type)
        return HStack(spacing: 12) {
            Image(systemName: st.icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(st.color)
                .frame(width: 34, height: 34)
                .background(st.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).font(.body.weight(.semibold)).lineLimit(2)
                if let t = e.time { Text(t).font(.caption).foregroundStyle(.secondary) }
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
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(add)
            Text(library.pcOnline ? "Der Hub erkennt Datum, Uhrzeit und Art (Arbeit, Hausaufgabe …) selbst."
                                  : "Ohne PC: wird eingetragen, sobald der Hub wieder erreichbar ist.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Eintragen", action: add)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
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
    private let cols = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    private var items: [HubData.Media] {
        let all = hub.data?.media ?? []
        return filter == "alle" ? all : all.filter { $0.status == filter }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Picker("Status", selection: $filter) {
                    Text("Läuft").tag("aktiv")
                    Text("Geplant").tag("geplant")
                    Text("Fertig").tag("fertig")
                    Text("Alle").tag("alle")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                LazyVGrid(columns: cols, spacing: 16) {
                    ForEach(items, id: \.id) { m in
                        Button { open = IDBox(id: m.id) } label: { MediaCard(m: m) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { plus(m, 1) } label: { Label("+1 Folge", systemImage: "plus") }
                                Button { plus(m, -1) } label: { Label("−1", systemImage: "minus") }
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
                MediaSheet(id: box.id).presentationDetents([.medium])
            }
        }
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
        VStack(alignment: .leading, spacing: 5) {
            RemoteImage(url: m.image, icon: "film")
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let n = m.newEp, n > 0 {
                        Text("+\(n)").font(.system(size: 10, weight: .heavy)).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.purple, in: Capsule()).padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let p = m.pct {
                        GeometryReader { g in
                            Capsule().fill(Color.purple).frame(width: g.size.width * min(1, p / 100), height: 4)
                        }
                        .frame(height: 4)
                        .padding(6)
                    }
                }
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
                    .frame(width: 120, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(m.title).font(.title3.bold()).lineLimit(3)
                    Text(m.progress).font(.headline).foregroundStyle(.purple).contentTransition(.numericText())
                    if let p = m.pct { ProgressView(value: min(1, p / 100)).tint(.purple) }
                    if let n = m.newEp, n > 0 { Label("\(n) neue Folge\(n == 1 ? "" : "n")", systemImage: "sparkles").font(.subheadline).foregroundStyle(.pink) }
                    Spacer(minLength: 8)
                    HStack(spacing: 10) {
                        Button { bump(-1) } label: { Image(systemName: "minus").frame(width: 30, height: 30) }
                            .buttonStyle(.bordered)
                        Button { bump(1) } label: { Label("Folge gesehen", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 30) }
                            .buttonStyle(.borderedProminent)
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
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardTitle(text: "Bosse", icon: "flag.checkered", color: .orange)
                    Spacer()
                    Text("\(done)/\(g.bosses.count)").font(.subheadline.monospacedDigit().weight(.bold)).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(done), total: Double(max(g.bosses.count, 1))).tint(.orange)
                ForEach(g.bosses, id: \.id) { b in
                    HStack(spacing: 12) {
                        Button { toggle(g, b) } label: {
                            Image(systemName: b.defeated ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(b.defeated ? Color.green : Color.secondary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.name).font(.body.weight(b.id == g.bossId ? .bold : .regular)).strikethrough(b.defeated).foregroundStyle(b.defeated ? .secondary : .primary)
                            if b.id == g.bossId && !b.defeated { Text("aktueller Boss").font(.caption2.weight(.bold)).foregroundStyle(.orange) }
                        }
                        Spacer()
                        if b.deaths > 0 { Label("\(b.deaths)", systemImage: "skull.fill").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !b.defeated, b.id != g.bossId else { return }
                        hub.act(["type": "boss-active", "game": g.id, "boss": b.id]) { d in
                            if let i = d.games.firstIndex(where: { $0.id == g.id }) { d.games[i].bossId = b.id }
                        }
                    }
                }
                Text("Tippen = aktueller Boss, Kreis = besiegt").font(.caption2).foregroundStyle(.tertiary)
            }
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
        let games = (hub.data?.games ?? []).filter { $0.id != hub.data?.active }
        return VStack(alignment: .leading, spacing: 10) {
            if !games.isEmpty { Text("Bibliothek").font(.title3.bold()).padding(.top, 4) }
            ForEach(games, id: \.id) { g in
                HStack(spacing: 12) {
                    RemoteImage(url: g.image, icon: "gamecontroller")
                        .frame(width: 92, height: 43)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.name).font(.body.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 6) {
                            if let s = g.status { Text(status[s] ?? s) }
                            if g.counts == true { Label("\(g.deaths)", systemImage: "skull.fill") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Spielen") {
                        hub.act(["type": "game-active", "game": g.id]) { d in d.active = g.id }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption.weight(.semibold))
                }
            }
        }
    }
}

struct ActiveGameCard: View {
    let game: HubData.Game
    @EnvironmentObject var hub: HubStore

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(game.name).font(.title2.bold()).lineLimit(1).shadow(radius: 6)
                if let b = game.currentBoss {
                    Label(b.name, systemImage: "flame.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            Text("\(game.shownDeaths)")
                .font(.system(size: 84, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(game.shownDeaths)))
                .shadow(color: .red.opacity(0.7), radius: 18)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: game.shownDeaths)
            Text(game.currentBoss != nil ? "Tode bei diesem Boss · \(game.deaths) gesamt" : "Tode gesamt")
                .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 18) {
                Button { death(-1) } label: {
                    Image(systemName: "minus").font(.title2.weight(.bold)).frame(width: 64, height: 64)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                Button { death(1) } label: {
                    Label("Tod", systemImage: "skull.fill").font(.title3.weight(.heavy)).frame(width: 150, height: 64)
                }
                .glassEffect(.regular.tint(.red.opacity(0.6)).interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .heavy), trigger: game.deaths)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                RemoteImage(url: game.image, icon: "gamecontroller").blur(radius: 18).opacity(0.75)
                LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
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
