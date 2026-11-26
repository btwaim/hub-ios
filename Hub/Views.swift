import SwiftUI

// MARK: - Grundgerüst

struct RootView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var nav: Nav
    @Namespace private var ns

    var body: some View {
        TabView(selection: $nav.tab) {
            Tab("Musik", systemImage: "music.note", value: 1) { MusicView() }
            Tab("Start", systemImage: "house.fill", value: 0) { HomeView() }
            Tab("Kalender", systemImage: "calendar", value: 2) { CalendarView() }
            Tab("Watchlist", systemImage: "play.tv.fill", value: 3) { WatchlistView() }
            Tab("Gaming", systemImage: "gamecontroller.fill", value: 4) { GamingView() }
        }
        .overlay { ToastOverlay() }
        .tabViewBottomAccessory {
            MiniPlayer()
                .matchedTransitionSource(id: "player", in: ns)
                .onTapGesture { nav.showPlayer = true }
        }
        .sheet(isPresented: $nav.showPlayer) {
            PlayerView()
                .navigationTransition(.zoom(sourceID: "player", in: ns))
                .presentationBackground(.black)
        }
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
    @State private var shownURL: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Group {
            if let size {
                content.frame(width: size, height: size).clipShape(shape)
            } else {
                Color.clear.aspectRatio(1, contentMode: .fit).overlay(content).clipShape(shape)
            }
        }
        .task(id: url) {
            let u = url
            let img = await CoverCache.shared.image(for: u, px: (size ?? 200) * 3)
            guard !Task.isCancelled, u == url else { return }
            image = img
            shownURL = u
        }
    }

    @ViewBuilder private var content: some View {
        if let image, shownURL == url {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [Color.white.opacity(0.1), Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").foregroundStyle(.white.opacity(0.3))
            }
        }
    }
}

/// kleine animierte Balken („läuft gerade“)
struct PlayingBars: View {
    let playing: Bool
    @State private var phase = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(Color.purple)
                    .frame(width: 3, height: playing ? (phase ? [12, 6, 10][i] : [5, 12, 7][i]) : 4)
            }
        }
        .frame(width: 15, height: 12, alignment: .bottom)
        .animation(playing ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true) : .default, value: phase)
        .onAppear { phase.toggle() }
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
                if query.isEmpty {
                    header
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(filtered) { t in
                    Button { player.play(t) } label: { TrackRow(track: t) }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(alignment: .top) {
                LinearGradient(colors: [Color.purple.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom).frame(height: 420).ignoresSafeArea()
            }
            .navigationTitle("Musik")
            .searchable(text: $query, prompt: "Song oder Künstler")
            .refreshable { await library.refresh() }
            .overlay {
                if library.tracks.isEmpty {
                    ContentUnavailableView("Noch keine Songs", systemImage: "music.note.list", description: Text("Öffne die App einmal, während der PC an ist – dann lädt sie deine Playlist."))
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                // Mosaik aus den ersten vier Covern
                let firsts = Array(library.tracks.prefix(4))
                LazyVGrid(columns: [GridItem(.fixed(52), spacing: 2), GridItem(.fixed(52), spacing: 2)], spacing: 2) {
                    ForEach(firsts) { t in CoverImage(url: t.cover, size: 52, corner: 0) }
                }
                .frame(width: 106, height: 106)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hub-Playlist").font(.title3.bold())
                    Text("\(library.tracks.count) Songs · im Hub-Sound").font(.subheadline).foregroundStyle(.secondary)
                    SyncStatus()
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                // Hauptknopf: deine Main-Songs (Rotation am PC) gemischt
                Button { player.shufflePlay(main: true) } label: {
                    VStack(spacing: 1) {
                        Label("Main mischen", systemImage: "shuffle").font(.headline)
                        Text("\(player.mainCount) Songs").font(.caption2).opacity(0.75)
                    }
                    .frame(maxWidth: .infinity).frame(height: 54)
                }
                .glassEffect(.regular.tint(.purple.opacity(0.6)).interactive(), in: .rect(cornerRadius: 16))
                .disabled(player.mainCount == 0)
                Button { player.shufflePlay(main: false) } label: {
                    VStack(spacing: 1) {
                        Label("Alle mischen", systemImage: "shuffle").font(.headline)
                        Text("\(library.tracks.count) Songs").font(.caption2).opacity(0.75)
                    }
                    .frame(maxWidth: .infinity).frame(height: 54)
                }
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                Button {
                    player.shuffle = false
                    if let f = library.tracks.first(where: { library.isOffline($0) }) ?? library.tracks.first { player.play(f) }
                } label: {
                    Image(systemName: "play.fill").font(.headline).frame(width: 54, height: 54)
                }
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                .accessibilityLabel("Der Reihe nach abspielen")
            }
            .buttonStyle(.plain)
            if player.mainCount == 0 && !library.tracks.isEmpty {
                Text("Main = deine Rotation. Am PC im Hub bei einem Song auf die Fahne tippen („Ab hier ist meine Rotation“).")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
    }
}

struct SyncStatus: View {
    @EnvironmentObject var library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(library.pcOnline ? Color.green : Color.gray).frame(width: 7, height: 7)
                if let p = library.progress {
                    Text("Lädt \(p.done)/\(p.total)").lineLimit(1)
                } else {
                    Text("\(library.offlineCount)/\(library.tracks.count) offline")
                }
            }
            if let p = library.progress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).tint(.purple).frame(maxWidth: 160)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct TrackRow: View {
    let track: Track
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player

    var body: some View {
        let current = player.current?.id == track.id
        HStack(spacing: 12) {
            CoverImage(url: track.cover, size: 50, corner: 9)
                .overlay {
                    if current {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.black.opacity(0.45))
                        PlayingBars(playing: player.isPlaying)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.body.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(current ? Color.purple : Color.primary)
                HStack(spacing: 6) {
                    if !library.isOffline(track) { Image(systemName: "icloud").font(.caption2) }
                    Text(track.artist).lineLimit(1)
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let label = track.fx?.label, !label.isEmpty {
                Text(label).font(.caption2.weight(.bold)).foregroundStyle(.purple)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.purple.opacity(0.15), in: Capsule())
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .opacity(library.isOffline(track) || library.pcOnline ? 1 : 0.45)
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var player: Player

    var body: some View {
        HStack(spacing: 10) {
            HDCover(track: player.current, corner: 8, px: 120).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(player.current?.title ?? "Nichts läuft").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(player.current?.artist ?? "Tippe einen Song an").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title3).frame(width: 36, height: 36) }
                .buttonStyle(.plain)
        }
        .padding(.leading, 10).padding(.trailing, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Mehr / Einrichtung

struct SettingsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: library.pcOnline ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                            .font(.title2).foregroundStyle(library.pcOnline ? Color.green : Color.secondary)
                            .frame(width: 44, height: 44)
                            .background((library.pcOnline ? Color.green : Color.gray).opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(library.pcOnline ? "Hub verbunden" : "Hub nicht erreichbar").font(.headline)
                            Text(Config.base?.host ?? "–").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Jetzt verbinden") { Task { await library.refresh() } }
                } header: { Text("PC") }
                Section {
                    Toggle("Lyrics auf Sperrbildschirm & Dynamic Island", isOn: $player.liveLyrics)
                    Toggle("3D-Musik (Spatial Audio)", isOn: $player.spatial)
                } header: { Text("Wiedergabe") } footer: {
                    Text("Cover, Knöpfe und Fortschritt zeigt Apple selbst auf dem Sperrbildschirm – Hub ergänzt nur die leuchtenden Lyrics. AirPods: rausnehmen pausiert, wieder rein spielt weiter.")
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
                    LabeledContent("GTA-Karte", value: "GTADB.ORG · CC BY 4.0")
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fertig") { dismiss() } } }
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
