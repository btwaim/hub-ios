import SwiftUI

// MARK: - HD-Cover

struct HDCover: View {
    let track: Track?
    var corner: CGFloat = 18
    @EnvironmentObject var library: Library
    @State private var image: UIImage?

    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { CoverImage(url: track?.big ?? track?.cover, size: nil, corner: 0) }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .task(id: track?.id) {
                image = nil
                guard let t = track else { return }
                image = await ArtStore.shared.image(for: t, allowNetwork: library.pcOnline)
            }
    }
}

/// Großes, unscharfes Cover als Hintergrund (wie Apple Music)
struct CoverBackdrop: View {
    let track: Track?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .blur(radius: 70, opaque: true)
                    .saturation(1.4)
                    .opacity(0.75)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: image != nil)
        .task(id: track?.id) {
            guard let t = track else { image = nil; return }
            if let c = await ArtStore.shared.cached(t) { image = c } else { image = await CoverCache.shared.image(for: t.big ?? t.cover) }
        }
    }
}

// MARK: - Großer Player

struct PlayerView: View {
    enum Mode: Int { case cover, lyrics, mp3 }
    @EnvironmentObject var player: Player
    @EnvironmentObject var lyrics: Lyrics
    @EnvironmentObject var library: Library
    @AppStorage("playerMode") private var modeRaw = 0
    @State private var scrub: Double?
    @State private var showFx = false

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .cover }

    var body: some View {
        ZStack {
            CoverBackdrop(track: player.current)
            VStack(spacing: 16) {
                Capsule().fill(Color.white.opacity(0.35)).frame(width: 40, height: 5).padding(.top, 10)
                Group {
                    switch mode {
                    case .cover:
                        Spacer(minLength: 0)
                        HDCover(track: player.current)
                            .shadow(color: .black.opacity(0.55), radius: 30, y: 18)
                            .scaleEffect(player.isPlaying ? 1 : 0.88)
                            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)
                        Spacer(minLength: 0)
                    case .lyrics:
                        LyricsGlowView()
                    case .mp3:
                        Spacer(minLength: 0)
                        MP3PlayerView()
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxHeight: .infinity)
                titleRow
                progress
                controls
                bottomRow
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .foregroundStyle(.white)
        .task(id: player.current?.id) { await lyrics.load(player.current) }
        .sheet(isPresented: $showFx) { FxSheet().presentationDetents([.medium]).presentationBackground(.ultraThinMaterial) }
    }

    private var titleRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "Nichts läuft").font(.title2.bold()).lineLimit(1)
                Text(player.current?.artist ?? "").font(.body).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer()
            Button { showFx = true } label: {
                let label = player.currentFx.label
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                    if !label.isEmpty { Text(label).lineLimit(1) }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var progress: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { scrub ?? player.time }, set: { scrub = $0 }), in: 0...max(player.duration, 1)) { editing in
                if !editing, let s = scrub { player.seek(to: s); scrub = nil }
            }
            .tint(.white)
            HStack {
                Text(formatTime(scrub ?? player.time))
                Spacer()
                Text("-" + formatTime(max(0, player.duration - (scrub ?? player.time))))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
        }
    }

    private var controls: some View {
        HStack {
            Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(player.shuffle ? Color.purple : .white.opacity(0.6)) }
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 30)) }
            Spacer()
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 44))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 72, height: 72)
            }
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)) }
            Spacer()
            Button {
                player.repeatMode = Player.Repeat(rawValue: (player.repeatMode.rawValue + 1) % 3) ?? .off
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.6) : Color.purple)
            }
        }
        .buttonStyle(.plain)
        .font(.title3)
    }

    private var bottomRow: some View {
        HStack(spacing: 26) {
            Button { withAnimation(.spring) { modeRaw = mode == .lyrics ? 0 : 1 } } label: {
                Image(systemName: "quote.bubble").foregroundStyle(mode == .lyrics ? Color.purple : .white.opacity(0.6))
            }
            Button { withAnimation(.spring) { modeRaw = mode == .mp3 ? 0 : 2 } } label: {
                Image(systemName: "ipod").foregroundStyle(mode == .mp3 ? Color.purple : .white.opacity(0.6))
            }
            Spacer()
            Button { player.spatial.toggle() } label: {
                Image(systemName: "airpods.pro").symbolEffect(.bounce, value: player.spatial)
                    .foregroundStyle(player.spatial ? Color.purple : .white.opacity(0.6))
            }
            Menu {
                Button("Aus") { player.setSleep(.off) }
                Button("15 Minuten") { player.setSleep(.minutes(15)) }
                Button("30 Minuten") { player.setSleep(.minutes(30)) }
                Button("60 Minuten") { player.setSleep(.minutes(60)) }
                Button("Nach diesem Song") { player.setSleep(.endOfSong) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz")
                    if let end = player.sleepEnds { Text(end, style: .timer).monospacedDigit().font(.caption) }
                    else if player.sleep == .endOfSong { Text("Songende").font(.caption) }
                }
                .foregroundStyle(player.sleep == .off ? .white.opacity(0.6) : Color.purple)
            }
        }
        .font(.title3)
        .buttonStyle(.plain)
    }
}

// MARK: - Effekte (Tempo / Bass / Hall)

struct FxSheet: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var library: Library
    @State private var rate: Double = 1
    @State private var bass: Double = 0
    @State private var reverb = false
    private let rates: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.5]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Sound").font(.title2.bold())
                Spacer()
                Button("Normal") { rate = 1; bass = 0; reverb = false; apply() }
                    .buttonStyle(.bordered).tint(.white)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Tempo", systemImage: "gauge.with.dots.needle.67percent")
                    Spacer()
                    Text(String(format: "%.2f×", rate) + (rate < 1 ? " · Slowed" : rate > 1 ? " · Sped up" : "")).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $rate, in: 0.7...2, step: 0.05) { e in if !e { apply() } }.tint(.purple)
                HStack {
                    ForEach(rates, id: \.self) { r in
                        Button(String(format: "%g×", r)) { rate = r; apply() }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            .tint(abs(rate - r) < 0.001 ? Color.purple : Color.gray)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Bass-Boost", systemImage: "speaker.wave.3.fill")
                    Spacer()
                    Text(bass > 0 ? "\(Int(bass)) %" : "aus").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $bass, in: 0...100, step: 5) { e in if !e { apply() } }.tint(.purple)
            }
            Toggle(isOn: Binding(get: { reverb }, set: { reverb = $0; apply() })) { Label("Hall", systemImage: "waveform.path") }
                .tint(.purple)
            Text(status).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .onAppear {
            let f = player.currentFx
            rate = f.rate ?? 1; bass = f.bass ?? 0; reverb = f.reverb ?? false
        }
    }

    private var status: String {
        guard let t = player.current else { return "" }
        if library.pending[t.id] != nil {
            return library.pcOnline ? "Du hörst die Änderung schon. Der PC rechnet gerade den exakten Hub-Sound." : "Du hörst die Änderung schon. Sobald der PC erreichbar ist, rechnet er den exakten Hub-Sound."
        }
        return player.reverbPending ? "Hall kommt mit der exakten Fassung vom PC." : "Gilt für diesen Song – auch am PC im Hub und fürs Edit."
    }

    private func apply() {
        player.setFx(Fx(rate: (rate * 100).rounded() / 100, bass: bass, reverb: reverb))
    }
}

// MARK: - Lyrics wie am PC (Glow, Unschärfe nach Abstand, Wörter leuchten nacheinander)

struct LyricsGlowView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var lyrics: Lyrics

    var body: some View {
        let idx = player.lyricIndex ?? lyrics.index(at: player.time, rate: player.bakedRate)
        let nowMs = player.time * 1000 * player.bakedRate
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    if lyrics.lines.isEmpty {
                        Text(lyrics.loadingFor != nil ? "Lade Lyrics …" : (lyrics.plain ?? "Keine Lyrics gefunden"))
                            .font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                            .padding(.top, 80)
                    }
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                        let dist = Double(abs(i - (idx ?? -10)))
                        let isCur = i == idx
                        lineText(line, current: isCur, nowMs: nowMs)
                            .font(.system(size: 28, weight: .bold, design: .default))
                            .tracking(-0.4)
                            .opacity(isCur ? 1 : max(0.16, 0.5 - dist * 0.08))
                            .blur(radius: isCur ? 0 : min(dist * 0.7, 2.4))
                            .scaleEffect(isCur ? 1.06 : 1, anchor: .leading)
                            .shadow(color: .white.opacity(isCur ? 0.35 : 0), radius: 12)
                            .animation(.spring(response: 0.7, dampingFraction: 0.75), value: isCur)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                            .onTapGesture { player.seek(to: line.ms / 1000 / max(player.bakedRate, 0.1)) }
                    }
                }
                .padding(.vertical, 160)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: idx) { _, n in
                if let n { withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { proxy.scrollTo(n, anchor: .center) } }
            }
        }
    }

    /// Aktuelle Zeile mit Wortzeiten: gesungene Wörter hell, kommende gedimmt
    private func lineText(_ line: LyricLine, current: Bool, nowMs: Double) -> Text {
        guard current, let words = line.words, !words.isEmpty else { return Text(line.text.isEmpty ? "♪" : line.text) }
        var out = Text("")
        for (k, w) in words.enumerated() {
            let sung = w.ms <= nowMs
            out = out + Text((k > 0 ? " " : "") + w.text).foregroundColor(sung ? .white : .white.opacity(0.45))
        }
        return out
    }
}

// MARK: - MP3-Player-Modus (quadratisch, LCD-Look)

struct MP3PlayerView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var lyrics: Lyrics

    private let lcd = Color(red: 0.78, green: 0.84, blue: 0.80)
    private let ink = Color(red: 0.08, green: 0.12, blue: 0.10)

    var body: some View {
        let idx = player.lyricIndex ?? lyrics.index(at: player.time, rate: player.bakedRate)
        let lines = lyrics.lines
        VStack(spacing: 0) {
            // Statusleiste wie bei einem MP3-Player
            HStack(spacing: 6) {
                Image(systemName: player.isPlaying ? "play.fill" : "pause.fill")
                Text(formatTime(player.time))
                Spacer()
                Text(player.current?.title.uppercased() ?? "HUB").lineLimit(1)
                Spacer()
                Image(systemName: "battery.75percent")
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(ink.opacity(0.1))
            Rectangle().fill(ink.opacity(0.6)).frame(height: 1.5)
            // Lyrics: eine Zeile vorher, die aktuelle groß und invertiert, zwei danach
            VStack(alignment: .leading, spacing: 14) {
                if lines.isEmpty {
                    Text(lyrics.loadingFor != nil ? "LADE LYRICS..." : "KEINE LYRICS").font(.system(size: 18, weight: .bold, design: .monospaced))
                } else {
                    let i = idx ?? -1
                    ForEach(max(0, i - 1)...min(lines.count - 1, max(i, 0) + 2), id: \.self) { k in
                        let text = lines[k].text.isEmpty ? "♪ ♪ ♪" : lines[k].text.uppercased()
                        if k == i {
                            Text(text)
                                .font(.system(size: 20, weight: .heavy, design: .monospaced))
                                .tracking(1.2)
                                .foregroundStyle(lcd)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(ink)
                        } else {
                            Text(text)
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .tracking(1.2)
                                .opacity(k < i ? 0.35 : 0.7)
                                .padding(.horizontal, 8)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 16).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.easeOut(duration: 0.25), value: idx)
            // Fortschrittsbalken in Blöcken
            GeometryReader { g in
                let n = 24
                let done = Int((player.time / max(player.duration, 1)) * Double(n))
                HStack(spacing: 3) {
                    ForEach(0..<n, id: \.self) { k in Rectangle().fill(ink.opacity(k < done ? 0.9 : 0.15)) }
                }
                .frame(width: g.size.width, height: 10)
            }
            .frame(height: 10)
            .padding(12)
        }
        .foregroundStyle(ink)
        .background(LinearGradient(colors: [lcd, lcd.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.black.opacity(0.6), lineWidth: 6))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
    }
}
