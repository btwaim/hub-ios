import SwiftUI

// MARK: - Grundgerüst

struct RootView: View {
    @EnvironmentObject var player: Player
    @State private var showPlayer = false

    var body: some View {
        TabView {
            Tab("Musik", systemImage: "music.note") { MusicView() }
            Tab("Wecker", systemImage: "alarm") { AlarmView() }
            Tab("Mehr", systemImage: "gearshape") { SettingsView() }
        }
        .tabViewBottomAccessory {
            MiniPlayer().onTapGesture { showPlayer = true }
        }
        .sheet(isPresented: $showPlayer) { PlayerView() }
        .alert(player.message ?? "", isPresented: Binding(get: { player.message != nil }, set: { if !$0 { player.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

struct CoverImage: View {
    let url: String?
    var size: CGFloat?
    var corner: CGFloat = 8
    @State private var image: UIImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Group {
            if let size {
                content.frame(width: size, height: size).clipShape(shape)
            } else {
                Color.clear.aspectRatio(1, contentMode: .fit).overlay(content).clipShape(shape)
            }
        }
        .task(id: url) { image = await CoverCache.shared.image(for: url) }
    }

    @ViewBuilder private var content: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Rectangle().fill(Color.white.opacity(0.08))
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Musik

struct MusicView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @State private var query = ""

    private var filtered: [Track] {
        query.isEmpty ? library.tracks : library.tracks.filter { "\($0.title) \($0.artist)".localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section { SyncStatus() }
                Section {
                    ForEach(filtered) { t in
                        Button { player.play(t) } label: { TrackRow(track: t) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Musik")
            .searchable(text: $query, prompt: "Song oder Künstler")
            .refreshable { await library.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { player.shuffle.toggle() } label: {
                        Image(systemName: "shuffle").foregroundStyle(player.shuffle ? Color.purple : Color.secondary)
                    }
                }
            }
            .overlay {
                if library.tracks.isEmpty {
                    ContentUnavailableView("Noch keine Songs", systemImage: "music.note.list", description: Text("Öffne die App einmal, während der PC an ist – dann lädt sie deine Playlist."))
                }
            }
        }
    }
}

struct SyncStatus: View {
    @EnvironmentObject var library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(library.pcOnline ? Color.green : Color.gray).frame(width: 8, height: 8)
                if let p = library.progress {
                    Text("Speichere offline \(p.done)/\(p.total) · \(p.title)").lineLimit(1)
                } else {
                    Text("\(library.pcOnline ? "PC verbunden" : "Ohne PC") · \(library.offlineCount)/\(library.tracks.count) offline")
                }
            }
            if let p = library.progress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).tint(.purple)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

struct TrackRow: View {
    let track: Track
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: track.cover, size: 46, corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.body.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(player.current?.id == track.id ? Color.purple : Color.primary)
                Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let label = track.fx?.label, !label.isEmpty {
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.purple)
            }
            Image(systemName: library.isOffline(track) ? "arrow.down.circle.fill" : "icloud")
                .font(.caption)
                .foregroundStyle(library.isOffline(track) ? Color.green : Color.secondary)
        }
        .contentShape(Rectangle())
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var player: Player

    var body: some View {
        HStack(spacing: 10) {
            CoverImage(url: player.current?.cover, size: 32, corner: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(player.current?.title ?? "Nichts läuft").font(.subheadline.weight(.semibold)).lineLimit(1)
                if let a = player.current?.artist { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                .buttonStyle(.plain)
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title3) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - Großer Player

struct PlayerView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var lyrics: Lyrics
    @State private var showLyrics = false
    @State private var scrub: Double?

    var body: some View {
        VStack(spacing: 18) {
            Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 10)
            if showLyrics {
                LyricsView()
            } else {
                Spacer(minLength: 0)
                CoverImage(url: player.current?.cover, size: nil, corner: 18)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                    .padding(.horizontal, 8)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? "Nichts läuft").font(.title2.bold()).lineLimit(1)
                    Text(player.current?.artist ?? "").foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let label = player.current?.fx?.label, !label.isEmpty {
                    Text(label).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.purple.opacity(0.2), in: Capsule()).foregroundStyle(.purple)
                }
            }
            VStack(spacing: 4) {
                Slider(value: Binding(get: { scrub ?? player.time }, set: { scrub = $0 }), in: 0...max(player.duration, 1)) { editing in
                    if !editing, let s = scrub { player.seek(to: s); scrub = nil }
                }
                HStack {
                    Text(formatTime(scrub ?? player.time))
                    Spacer()
                    Text("-" + formatTime(max(0, player.duration - (scrub ?? player.time))))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(player.shuffle ? Color.purple : Color.secondary) }
                Spacer()
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                Spacer()
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 68)) }
                Spacer()
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
                Spacer()
                Button {
                    player.repeatMode = Player.Repeat(rawValue: (player.repeatMode.rawValue + 1) % 3) ?? .off
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.purple)
                }
            }
            .buttonStyle(.plain)
            .font(.title3)
            HStack {
                Button { withAnimation { showLyrics.toggle() } } label: {
                    Image(systemName: "quote.bubble").foregroundStyle(showLyrics ? Color.purple : Color.secondary)
                }
                Spacer()
                Menu {
                    Button("Aus") { player.setSleep(.off) }
                    Button("15 Minuten") { player.setSleep(.minutes(15)) }
                    Button("30 Minuten") { player.setSleep(.minutes(30)) }
                    Button("60 Minuten") { player.setSleep(.minutes(60)) }
                    Button("Nach diesem Song") { player.setSleep(.endOfSong) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "moon.zzz")
                        if let end = player.sleepEnds { Text(end, style: .timer).monospacedDigit() }
                        else if player.sleep == .endOfSong { Text("nach dem Song") }
                    }
                    .foregroundStyle(player.sleep == .off ? Color.secondary : Color.purple)
                }
            }
            .font(.title3)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .task(id: player.current?.id) { await lyrics.load(player.current) }
    }
}

struct LyricsView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var lyrics: Lyrics

    var body: some View {
        let rate = player.current?.rate ?? 1
        let idx = lyrics.index(at: player.time, rate: rate)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if lyrics.lines.isEmpty {
                        Text(lyrics.loadingFor != nil ? "Lade Lyrics …" : (lyrics.plain ?? "Keine Lyrics gefunden"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(i == idx ? Color.primary : Color.secondary.opacity(0.55))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                            .onTapGesture { player.seek(to: line.ms / 1000 / max(rate, 0.1)) }
                    }
                }
                .padding(.vertical, 40)
            }
            .onChange(of: idx) { _, n in
                if let n { withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(n, anchor: .center) } }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Wecker

struct AlarmView: View {
    @EnvironmentObject var alarms: Alarms

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Wecker nach Stundenplan", isOn: $alarms.enabled)
                    if !alarms.status.isEmpty { Text(alarms.status).font(.footnote).foregroundStyle(.secondary) }
                } footer: {
                    Text("Die Weckzeiten kommen aus deinem Stundenplan im Hub, Entfälle und Vertretungen eingerechnet. Die Wecker liegen auf dem iPhone und klingeln auch, wenn der PC aus ist.")
                }
                Section("Nächste Tage") {
                    ForEach(alarms.days) { d in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dayTitle(d)).font(.body.weight(.semibold))
                                Text(d.free ? "frei · ausschlafen" : [d.period.map { "\($0). Stunde" }, d.subject].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if d.free { Text("–").foregroundStyle(.secondary) }
                            else {
                                Text(d.wake ?? "").font(.title3.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(alarms.scheduled[d.date] != nil ? Color.purple : Color.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Wecker")
            .refreshable { await alarms.refresh() }
        }
    }

    private func dayTitle(_ d: WakeDay) -> String {
        guard let date = d.dayDate else { return d.label ?? d.date }
        if Calendar.current.isDateInToday(date) { return "Heute" }
        if Calendar.current.isDateInTomorrow(date) { return "Morgen" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, d. MMM"
        return f.string(from: date)
    }
}

// MARK: - Mehr / Einrichtung

struct SettingsView: View {
    @EnvironmentObject var library: Library
    @State private var link = ""
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Verbindung") {
                    LabeledContent("Hub", value: Config.base?.host ?? "–")
                    LabeledContent("Status", value: library.pcOnline ? "verbunden" : "nicht erreichbar")
                    Button("Jetzt verbinden") { Task { await library.refresh() } }
                }
                Section("Offline") {
                    LabeledContent("Songs", value: "\(library.offlineCount) von \(library.tracks.count)")
                    LabeledContent("Speicher", value: "\(library.storageMB) MB")
                    Button("Alle Songs neu laden", role: .destructive) { confirmClear = true }
                }
                Section {
                    TextField("hubapp://… oder https://…/music?t=…", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Übernehmen") {
                        if let u = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), Config.apply(link: u) {
                            link = ""
                            Task { await library.refresh() }
                        }
                    }
                } header: { Text("Neu verbinden") } footer: { Text("QR-Code vom Hub mit der Kamera scannen oder den Link hier einfügen.") }
                Section {
                    LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
                }
            }
            .navigationTitle("Mehr")
            .confirmationDialog("Alle Offline-Songs löschen und neu laden?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Neu laden", role: .destructive) { library.clearOffline(); Task { await library.sync() } }
            }
        }
    }
}

struct SetupView: View {
    var done: () -> Void
    @State private var link = ""
    @State private var failed = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "music.note.house.fill").font(.system(size: 64)).foregroundStyle(.purple)
            Text("Hub verbinden").font(.largeTitle.bold())
            Text("Scanne am PC den QR-Code „Hub App einrichten“ vom Desktop mit der Kamera-App – oder füge den Link hier ein.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            TextField("Link einfügen", text: $link)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Verbinden") {
                if let u = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), Config.apply(link: u) { done() }
                else { failed = true }
            }
            .buttonStyle(.borderedProminent)
            if failed { Text("Link nicht erkannt").foregroundStyle(.red) }
            Spacer()
        }
        .padding(28)
    }
}
