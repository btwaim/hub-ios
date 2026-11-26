import SwiftUI
import AVKit

// MARK: - Cover (nie ein falsches: Ergebnis zählt nur, wenn noch derselbe Song gemeint ist)

struct HDCover: View {
    let track: Track?
    var corner: CGFloat = 18
    /// Zielgröße in Pixeln (kleine Anzeigen bekommen eine verkleinerte Fassung → flüssiges Scrollen)
    var px: CGFloat = 1000
    @EnvironmentObject var library: Library
    @State private var image: UIImage?
    @State private var shownID: String?

    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    CoverImage(url: track?.cover, size: nil, corner: 0)
                    if let image, shownID == track?.id {
                        Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .animation(.easeOut(duration: 0.25), value: shownID)
            .task(id: track?.id) {
                guard let t = track else { image = nil; shownID = nil; return }
                let id = t.id
                let img = await ArtStore.shared.thumb(for: t, px: px, allowNetwork: library.pcOnline)
                guard !Task.isCancelled, track?.id == id else { return }
                image = img
                shownID = img == nil ? nil : id
            }
    }
}

/// Großes, unscharfes Cover als Hintergrund (wie Apple Music)
struct CoverBackdrop: View {
    let track: Track?
    @State private var image: UIImage?
    @State private var shownID: String?

    var body: some View {
        // Wichtig: Das Bild liegt als Overlay auf einer Fläche – so bestimmt es NICHT die Größe
        // (sonst wird der Player breiter als der Bildschirm und man sieht nur die linke Hälfte)
        Color.black
            .overlay {
                if let image, shownID == track?.id {
                    // winziges Bild (96 px) unscharf hochgezogen: sieht gleich aus, kostet beim Scrollen fast nichts
                    Image(uiImage: image).resizable().scaledToFill()
                        .blur(radius: 40, opaque: true)
                        .saturation(1.5)
                        .opacity(0.8)
                        .transition(.opacity)
                }
            }
            .overlay {
                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.35), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.7), value: shownID)
        .task(id: track?.id) {
            guard let t = track else { image = nil; shownID = nil; return }
            let id = t.id
            let img = await ArtStore.shared.thumb(for: t, px: 96, allowNetwork: false)
            guard !Task.isCancelled, track?.id == id else { return }
            image = img
            shownID = id
        }
    }
}

/// AirPlay / AirPods-Auswahl (System-Knopf)
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor.white.withAlphaComponent(0.55)
        v.activeTintColor = UIColor(red: 0.66, green: 0.45, blue: 1, alpha: 1)
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Dünner Fortschrittsbalken wie bei Apple Music (wird beim Ziehen dicker)
struct ScrubBar: View {
    let time: Double
    let duration: Double
    var onSeek: (Double) -> Void
    @State private var drag: Double?

    var body: some View {
        let shown = drag ?? time
        VStack(spacing: 6) {
            GeometryReader { g in
                let p = duration > 0 ? min(1, max(0, shown / duration)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color.white.opacity(drag != nil ? 1 : 0.85)).frame(width: max(0, g.size.width * p))
                }
                .frame(height: drag != nil ? 12 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in drag = min(1, max(0, v.location.x / max(g.size.width, 1))) * duration }
                    .onEnded { _ in if let d = drag { onSeek(d) }; drag = nil })
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: drag != nil)
            }
            .frame(height: 20)
            HStack {
                Text(formatTime(shown))
                Spacer()
                Text("-" + formatTime(max(0, duration - shown)))
            }
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white.opacity(drag != nil ? 0.9 : 0.5))
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
    @State private var showFx = false

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .cover }

    var body: some View {
        GeometryReader { geo in
            let side = max(120, min(geo.size.width - 72, geo.size.height * 0.4, 330))
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Capsule().fill(Color.white.opacity(0.3)).frame(width: 36, height: 5).padding(.top, 8)
                    switch mode {
                    case .cover:
                        Spacer(minLength: 12)
                        HDCover(track: player.current, corner: 14)
                            .frame(width: side, height: side)
                            .shadow(color: .black.opacity(0.45), radius: 26, y: 16)
                            .scaleEffect(player.isPlaying ? 1 : 0.86)
                            .animation(.spring(response: 0.55, dampingFraction: 0.72), value: player.isPlaying)
                        Spacer(minLength: 12)
                        titleRow
                    case .lyrics:
                        compactHeader.padding(.top, 14)
                        LyricsGlowView().frame(maxHeight: .infinity)
                    case .mp3:
                        compactHeader.padding(.top, 14)
                        Spacer(minLength: 8)
                        MP3PlayerView().frame(width: side + 24, height: side + 24)
                        Spacer(minLength: 8)
                    }
                    ScrubBar(time: player.time, duration: player.duration) { player.seek(to: $0) }
                        .padding(.top, 14)
                    controls.padding(.vertical, 14)
                    bottomRow.padding(.bottom, 6)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
            }
            // fest auf die Bildschirmgröße – nichts darf breiter werden
            .frame(width: geo.size.width, height: geo.size.height)
            .foregroundStyle(.white)
        }
        .background { CoverBackdrop(track: player.current) }
        .task(id: player.current?.id) { await lyrics.load(player.current) }
        .sheet(isPresented: $showFx) {
            FxSheet()
                .presentationDetents([.height(470)])
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(32)
        }
    }

    /// Speed / Bass / Hall – gut sichtbar als Knopf mit Text
    private var fxButton: some View {
        Button { showFx = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                Text("Sound")
            }
            .font(.system(size: 14, weight: .bold))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(player.currentFx.label.isEmpty ? Color.white.opacity(0.16) : Color.purple.opacity(0.85), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speed, Bass und Hall einstellen")
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(player.current?.title ?? "Nichts läuft")
                    .font(.system(size: 21, weight: .bold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(player.current?.artist ?? "").lineLimit(1)
                    let fx = player.currentFx.label
                    if !fx.isEmpty {
                        Text(fx).font(.caption2.weight(.heavy)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.white.opacity(0.18), in: Capsule()).lineLimit(1)
                    }
                }
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            fxButton
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            HDCover(track: player.current, corner: 8, px: 170).frame(width: 52, height: 52)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "").font(.headline).lineLimit(1)
                Text(player.current?.artist ?? "").font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
            fxButton
        }
    }

    private var controls: some View {
        HStack {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { player.cycleShuffle() } } label: {
                Image(systemName: "shuffle").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(player.shuffle ? Color.white : .white.opacity(0.45))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(player.shuffle ? 0.2 : 0), in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if player.shuffle && player.shuffleMain {
                            Text("M").font(.system(size: 9, weight: .black)).foregroundStyle(.black)
                                .frame(width: 14, height: 14).background(Color.purple.mix(with: .white, by: 0.3), in: Circle())
                                .offset(x: 3, y: -3).transition(.scale.combined(with: .opacity))
                        }
                    }
            }
            .accessibilityLabel(player.shuffle ? (player.shuffleMain ? "Zufall: nur Main" : "Zufall: alle") : "Zufall aus")
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 30)) }
            Spacer()
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 42))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 64, height: 64)
            }
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)) }
            Spacer()
            Button {
                player.repeatMode = Player.Repeat(rawValue: (player.repeatMode.rawValue + 1) % 3) ?? .off
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.45) : Color.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(player.repeatMode == .off ? 0 : 0.2), in: Circle())
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
    }

    private var bottomRow: some View {
        HStack {
            modeButton(.lyrics, "quote.bubble.fill", "quote.bubble")
            Spacer()
            modeButton(.mp3, "ipod", "ipod")
            Spacer()
            RoutePicker().frame(width: 30, height: 30)
            Spacer()
            Button { player.spatial.toggle() } label: {
                Image(systemName: "airpods.pro")
                    .symbolEffect(.bounce, value: player.spatial)
                    .foregroundStyle(player.spatial ? Color.white : .white.opacity(0.45))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(player.spatial ? 0.2 : 0), in: Circle())
            }
            Spacer()
            Menu {
                Button("Aus") { player.setSleep(.off) }
                Button("15 Minuten") { player.setSleep(.minutes(15)) }
                Button("30 Minuten") { player.setSleep(.minutes(30)) }
                Button("60 Minuten") { player.setSleep(.minutes(60)) }
                Button("Nach diesem Song") { player.setSleep(.endOfSong) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "moon.zzz.fill")
                    if let end = player.sleepEnds { Text(end, style: .timer).monospacedDigit().font(.caption2.weight(.bold)) }
                }
                .foregroundStyle(player.sleep == .off ? .white.opacity(0.45) : Color.white)
                .frame(minWidth: 34, minHeight: 34)
            }
        }
        .font(.system(size: 18))
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private func modeButton(_ m: Mode, _ on: String, _ off: String) -> some View {
        Button { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { modeRaw = mode == m ? 0 : m.rawValue } } label: {
            Image(systemName: mode == m ? on : off)
                .foregroundStyle(mode == m ? Color.white : .white.opacity(0.45))
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(mode == m ? 0.2 : 0), in: Circle())
        }
    }
}

// MARK: - Effekte (Tempo / Bass / Hall)

struct FxSheet: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var library: Library
    @State private var rate: Double = 1
    @State private var bass: Double = 0
    @State private var reverb = false

    private struct Preset: Identifiable { let id: String; let icon: String; let rate: Double; let bass: Double; let reverb: Bool }
    private let presets = [
        Preset(id: "Normal", icon: "circle", rate: 1, bass: 0, reverb: false),
        Preset(id: "Sped up", icon: "hare.fill", rate: 1.15, bass: 0, reverb: false),
        Preset(id: "Nightcore", icon: "bolt.fill", rate: 1.3, bass: 0, reverb: false),
        Preset(id: "Slowed", icon: "tortoise.fill", rate: 0.85, bass: 0, reverb: true),
        Preset(id: "Bass", icon: "speaker.wave.3.fill", rate: 1, bass: 50, reverb: false)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sound").font(.title2.bold())
                Spacer()
                if let t = player.current { Text(t.title).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets) { p in
                        let on = abs(rate - p.rate) < 0.001 && abs(bass - p.bass) < 0.5 && reverb == p.reverb
                        Button {
                            rate = p.rate; bass = p.bass; reverb = p.reverb; apply()
                        } label: {
                            Label(p.id, systemImage: p.icon)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(on ? Color.purple : Color.white.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            sliderRow("Tempo", "gauge.with.dots.needle.67percent", String(format: "%.2f×", rate)) {
                Slider(value: $rate, in: 0.7...2, step: 0.05) { e in if !e { apply() } }
            }
            sliderRow("Bass", "speaker.wave.3.fill", bass > 0 ? "\(Int(bass)) %" : "aus") {
                Slider(value: $bass, in: 0...100, step: 5) { e in if !e { apply() } }
            }
            Toggle(isOn: Binding(get: { reverb }, set: { reverb = $0; apply() })) {
                Label("Hall", systemImage: "waveform.path").font(.subheadline.weight(.semibold))
            }
            Label(status, systemImage: statusIcon)
                .font(.footnote).foregroundStyle(.secondary)
        }
        .tint(.purple)
        .padding(24)
        .onAppear {
            let f = player.currentFx
            rate = f.rate ?? 1; bass = f.bass ?? 0; reverb = f.reverb ?? false
        }
    }

    private func sliderRow<S: View>(_ title: String, _ icon: String, _ value: String, @ViewBuilder slider: () -> S) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                Spacer()
                Text(value).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            slider()
        }
    }

    private var statusIcon: String {
        guard let t = player.current else { return "info.circle" }
        return library.pending[t.id] != nil ? "arrow.triangle.2.circlepath" : "checkmark.circle"
    }

    private var status: String {
        guard let t = player.current else { return "" }
        if library.pending[t.id] != nil {
            return library.pcOnline ? "Hörst du schon – der PC rechnet gerade den exakten Hub-Sound." : "Hörst du schon – der PC rechnet nach, sobald er an ist."
        }
        return player.reverbPending ? "Hall kommt mit der exakten Fassung vom PC." : "Gilt für diesen Song – auch am PC und fürs Edit."
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
                VStack(alignment: .leading, spacing: 22) {
                    if lyrics.lines.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: lyrics.loadingFor != nil ? "ellipsis" : "text.quote").font(.title)
                            Text(lyrics.loadingFor != nil ? "Lade Lyrics …" : (lyrics.plain ?? "Keine Lyrics für diesen Song"))
                                .font(.title3.weight(.semibold))
                        }
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 120)
                    }
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                        let dist = Double(abs(i - (idx ?? -10)))
                        let isCur = i == idx
                        lineText(line, current: isCur, nowMs: nowMs)
                            .font(.system(size: 30, weight: .heavy))
                            .tracking(-0.5)
                            .lineSpacing(2)
                            .opacity(isCur ? 1 : max(0.16, 0.5 - dist * 0.08))
                            .blur(radius: isCur ? 0 : min(dist * 0.7, 2.4))
                            .scaleEffect(isCur ? 1.04 : 1, anchor: .leading)
                            .shadow(color: .white.opacity(isCur ? 0.4 : 0), radius: 14)
                            .animation(.spring(response: 0.7, dampingFraction: 0.78), value: isCur)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                            .onTapGesture { player.seek(to: line.ms / 1000 / max(player.bakedRate, 0.1)) }
                    }
                }
                .padding(.vertical, 140)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                                         .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: idx) { _, n in
                if let n { withAnimation(.spring(response: 0.65, dampingFraction: 0.86)) { proxy.scrollTo(n, anchor: UnitPoint(x: 0, y: 0.38)) } }
            }
            .onAppear { if let n = idx { proxy.scrollTo(n, anchor: UnitPoint(x: 0, y: 0.38)) } }
        }
    }

    /// Aktuelle Zeile mit Wortzeiten: gesungene Wörter hell, kommende gedimmt
    private func lineText(_ line: LyricLine, current: Bool, nowMs: Double) -> Text {
        guard current, let words = line.words, !words.isEmpty else { return Text(line.text.isEmpty ? "♪" : line.text) }
        var out = Text("")
        for (k, w) in words.enumerated() {
            let sung = w.ms <= nowMs
            out = out + Text((k > 0 ? " " : "") + w.text).foregroundColor(sung ? .white : .white.opacity(0.4))
        }
        return out
    }
}

// MARK: - MP3-Player-Modus (quadratisch, LCD-Look)

struct MP3PlayerView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var lyrics: Lyrics

    private let lcd = Color(red: 0.76, green: 0.83, blue: 0.79)
    private let ink = Color(red: 0.07, green: 0.11, blue: 0.09)

    var body: some View {
        let idx = player.lyricIndex ?? lyrics.index(at: player.time, rate: player.bakedRate)
        let lines = lyrics.lines
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: player.isPlaying ? "play.fill" : "pause.fill")
                Text(formatTime(player.time))
                Spacer()
                Text(player.current?.title.uppercased() ?? "HUB").lineLimit(1)
                Spacer()
                Image(systemName: "battery.75percent")
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(ink.opacity(0.1))
            Rectangle().fill(ink.opacity(0.6)).frame(height: 1.5)
            VStack(alignment: .leading, spacing: 12) {
                if lines.isEmpty {
                    Text(lyrics.loadingFor != nil ? "LADE LYRICS..." : "KEINE LYRICS").font(.system(size: 16, weight: .bold, design: .monospaced))
                } else {
                    let i = idx ?? -1
                    ForEach(max(0, i - 1)...min(lines.count - 1, max(i, 0) + 2), id: \.self) { k in
                        let text = lines[k].text.isEmpty ? "♪ ♪ ♪" : lines[k].text.uppercased()
                        if k == i {
                            Text(text)
                                .font(.system(size: 18, weight: .heavy, design: .monospaced))
                                .tracking(1.1)
                                .foregroundStyle(lcd)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(ink)
                        } else {
                            Text(text)
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .tracking(1.1)
                                .opacity(k < i ? 0.35 : 0.7)
                                .padding(.horizontal, 8)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 14).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.easeOut(duration: 0.25), value: idx)
            GeometryReader { g in
                let n = 24
                let done = Int((player.time / max(player.duration, 1)) * Double(n))
                HStack(spacing: 3) {
                    ForEach(0..<n, id: \.self) { k in Rectangle().fill(ink.opacity(k < done ? 0.9 : 0.15)) }
                }
                .frame(width: g.size.width, height: 9)
            }
            .frame(height: 9)
            .padding(12)
        }
        .foregroundStyle(ink)
        .background(LinearGradient(colors: [lcd, lcd.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
        )
        .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
    }
}
