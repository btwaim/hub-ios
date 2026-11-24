import SwiftUI
import WidgetKit
import AppIntents

@main
struct HubWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        LyricsWidget()
        WakeWidget()
        WatchWidget()
        NowPlayingLiveActivity()
    }
}

// MARK: - Jetzt läuft

struct NowEntry: TimelineEntry {
    let date: Date
    let np: WidgetNowPlaying?
}

struct NowProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowEntry { NowEntry(date: Date(), np: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (NowEntry) -> Void) {
        completion(NowEntry(date: Date(), np: AppGroup.read(WidgetNowPlaying.self, "nowplaying.json") ?? .sample))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowEntry>) -> Void) {
        let np = AppGroup.read(WidgetNowPlaying.self, "nowplaying.json")
        let policy: TimelineReloadPolicy = np?.range.map { .after($0.upperBound) } ?? .never
        completion(Timeline(entries: [NowEntry(date: Date(), np: np)], policy: policy))
    }
}

extension WidgetNowPlaying {
    static let sample = WidgetNowPlaying(title: "My Alcoholic Friends", artist: "The Dresden Dolls", isPlaying: true,
                                         start: Date().addingTimeInterval(-70), end: Date().addingTimeInterval(110),
                                         lyrics: [WidgetLyric(at: Date(), text: "I've got my alcoholic friends")], coverFile: nil, fx: "1.1× · Bass 25 %")
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HubNowPlaying", provider: NowProvider()) { e in NowPlayingWidgetView(entry: e) }
            .configurationDisplayName("Jetzt läuft")
            .description("Song, Cover und Steuerung.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(URL(string: "hubapp://player"))
            .containerBackground(for: .widget) {
                if family == .systemSmall || family == .systemMedium { CoverGlow(file: entry.np?.coverFile, dim: 0.35) }
                else if family == .accessoryCircular { AccessoryWidgetBackground() }
                else { Color.clear }
            }
    }

    @ViewBuilder private var content: some View {
        if let np = entry.np {
            switch family {
            case .systemSmall: small(np)
            case .accessoryRectangular: rect(np)
            case .accessoryCircular: circular(np)
            default: medium(np)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note").font(.title2)
                Text("Nichts läuft").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func small(_ np: WidgetNowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                CoverThumb(file: np.coverFile, size: 58, corner: 12)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                Spacer()
                Button(intent: TogglePlayIntent()) {
                    Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            Text(np.title).font(.subheadline.weight(.bold)).lineLimit(1)
            Text(np.artist).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            bar(np).padding(.top, 6)
        }
        .foregroundStyle(.white)
    }

    private func medium(_ np: WidgetNowPlaying) -> some View {
        HStack(spacing: 14) {
            CoverThumb(file: np.coverFile, size: 118, corner: 16)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(np.title).font(.headline).lineLimit(2)
                Text(np.artist).font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                if !np.fx.isEmpty { Text(np.fx).font(.caption2.weight(.bold)).foregroundStyle(hubPurple).lineLimit(1) }
                Spacer(minLength: 4)
                bar(np)
                Controls(isPlaying: np.isPlaying, size: 22, spacing: 30)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
        }
        .foregroundStyle(.white)
    }

    private func rect(_ np: WidgetNowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: np.isPlaying ? "waveform" : "pause.fill").font(.caption2)
                Text(np.title).font(.headline).lineLimit(1)
            }
            .widgetAccentable()
            Text(np.artist).font(.caption).lineLimit(1).opacity(0.75)
            bar(np)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func circular(_ np: WidgetNowPlaying) -> some View {
        ZStack {
            if let r = np.range {
                ProgressView(timerInterval: r, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
                    .progressViewStyle(.circular)
            }
            Button(intent: TogglePlayIntent()) {
                Image(systemName: np.isPlaying ? "pause.fill" : "play.fill").font(.title3.weight(.bold))
            }
            .buttonStyle(.plain)
            .widgetAccentable()
        }
    }

    @ViewBuilder private func bar(_ np: WidgetNowPlaying) -> some View {
        if let r = np.range {
            ProgressView(timerInterval: r, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
                .tint(.white)
        } else {
            ProgressView(value: 0).tint(.white.opacity(0.5))
        }
    }
}

// MARK: - Lyrics (Zeile für Zeile im Takt)

struct LyricEntry: TimelineEntry {
    let date: Date
    let np: WidgetNowPlaying?
    let index: Int?
}

struct LyricProvider: TimelineProvider {
    func placeholder(in context: Context) -> LyricEntry { LyricEntry(date: Date(), np: .sample, index: 0) }
    func getSnapshot(in context: Context, completion: @escaping (LyricEntry) -> Void) {
        let np = AppGroup.read(WidgetNowPlaying.self, "nowplaying.json") ?? .sample
        completion(LyricEntry(date: Date(), np: np, index: np.lyrics.isEmpty ? nil : 0))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricEntry>) -> Void) {
        let now = Date()
        guard let np = AppGroup.read(WidgetNowPlaying.self, "nowplaying.json") else {
            completion(Timeline(entries: [LyricEntry(date: now, np: nil, index: nil)], policy: .never)); return
        }
        var entries = [LyricEntry(date: now, np: np, index: np.lyrics.lastIndex { $0.at <= now })]
        if np.isPlaying {
            for (i, l) in np.lyrics.enumerated() where l.at > now { entries.append(LyricEntry(date: l.at, np: np, index: i)) }
        }
        let policy: TimelineReloadPolicy = np.range.map { .after($0.upperBound) } ?? .never
        completion(Timeline(entries: entries, policy: policy))
    }
}

struct LyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HubLyrics", provider: LyricProvider()) { e in LyricsWidgetView(entry: e) }
            .configurationDisplayName("Lyrics")
            .description("Die Lyrics laufen mit – mit Leuchten wie im Hub.")
            .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct LyricsWidgetView: View {
    let entry: LyricEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(URL(string: "hubapp://player"))
            .containerBackground(for: .widget) {
                if family == .accessoryRectangular { Color.clear } else { CoverGlow(file: entry.np?.coverFile, dim: 0.5) }
            }
    }

    private var lines: [WidgetLyric] { entry.np?.lyrics ?? [] }

    @ViewBuilder private var content: some View {
        if let np = entry.np, !lines.isEmpty, np.isPlaying {
            if family == .accessoryRectangular { rect } else { big(np) }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "quote.bubble.fill").font(.title2).foregroundStyle(hubPurple)
                Text(entry.np == nil ? "Spiel einen Song in Hub" : (entry.np?.isPlaying == false ? "Pausiert" : "Keine Lyrics"))
                    .font(.headline)
                if let np = entry.np { Text(np.title + " · " + np.artist).font(.caption).opacity(0.6).lineLimit(1) }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var rect: some View {
        let i = entry.index ?? -1
        return VStack(alignment: .leading, spacing: 1) {
            Text(i >= 0 ? lines[i].text : "♪").font(.headline).lineLimit(2).widgetAccentable()
            if i + 1 < lines.count { Text(lines[i + 1].text).font(.caption).lineLimit(1).opacity(0.6) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func big(_ np: WidgetNowPlaying) -> some View {
        let i = entry.index ?? -1
        let after = family == .systemLarge ? 5 : 2
        return VStack(alignment: .leading, spacing: family == .systemLarge ? 12 : 7) {
            HStack(spacing: 8) {
                CoverThumb(file: np.coverFile, size: 22, corner: 5)
                Text(np.title).font(.caption.weight(.bold)).lineLimit(1)
                Spacer()
                Bars(playing: true)
            }
            .foregroundStyle(.white.opacity(0.8))
            if i - 1 >= 0 {
                Text(lines[i - 1].text).font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.3)).lineLimit(1).blur(radius: 0.6)
            }
            GlowLine(text: i >= 0 ? (lines[i].text.isEmpty ? "♪" : lines[i].text) : "♪ ♪ ♪", size: family == .systemLarge ? 26 : 20)
            ForEach(Array(lines.indices.filter { $0 > i && $0 <= i + after }), id: \.self) { k in
                Text(lines[k].text.isEmpty ? "♪" : lines[k].text)
                    .font(.system(size: family == .systemLarge ? 18 : 14, weight: .bold))
                    .foregroundStyle(.white.opacity(max(0.15, 0.5 - Double(k - i - 1) * 0.1)))
                    .blur(radius: min(Double(k - i) * 0.5, 1.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Wecker + Stundenplan

struct WakeEntry: TimelineEntry {
    let date: Date
    let days: [WidgetDay]
}

struct NextWake {
    let day: WidgetDay
    let at: Date

    static func find(_ days: [WidgetDay], after now: Date = Date()) -> NextWake? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var best: NextWake?
        for d in days where !d.free {
            guard let w = d.wake, let at = f.date(from: "\(d.date) \(w)"), at > now else { continue }
            if best == nil || at < best!.at { best = NextWake(day: d, at: at) }
        }
        return best
    }

    var dayName: String {
        let c = Calendar.current
        if c.isDateInToday(at) { return "Heute" }
        if c.isDateInTomorrow(at) { return "Morgen" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE"
        return f.string(from: at)
    }
    var detail: String {
        [day.period.map { "\($0). Stunde" }, day.subject].compactMap { $0 }.joined(separator: " · ")
    }
}

struct WakeProvider: TimelineProvider {
    func placeholder(in context: Context) -> WakeEntry { WakeEntry(date: Date(), days: []) }
    func getSnapshot(in context: Context, completion: @escaping (WakeEntry) -> Void) {
        completion(WakeEntry(date: Date(), days: AppGroup.read([WidgetDay].self, "wake.json") ?? []))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WakeEntry>) -> Void) {
        let days = AppGroup.read([WidgetDay].self, "wake.json") ?? []
        let next = NextWake.find(days)?.at.addingTimeInterval(60) ?? Date().addingTimeInterval(6 * 3600)
        completion(Timeline(entries: [WakeEntry(date: Date(), days: days)], policy: .after(next)))
    }
}

struct WakeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HubWake", provider: WakeProvider()) { e in WakeWidgetView(entry: e) }
            .configurationDisplayName("Wecker")
            .description("Nächste Weckzeit nach deinem Stundenplan.")
            .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct WakeWidgetView: View {
    let entry: WakeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let next = NextWake.find(entry.days, after: entry.date)
        Group {
            switch family {
            case .accessoryInline:
                if let n = next { Label("\(n.dayName) \(n.day.wake ?? "")", systemImage: "alarm.fill") }
                else { Label("Kein Wecker", systemImage: "alarm") }
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Image(systemName: "alarm.fill").font(.caption)
                    Text(next?.day.wake ?? "–").font(.system(size: 15, weight: .bold)).minimumScaleFactor(0.6)
                }
                .widgetAccentable()
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Label(next.map { "\($0.dayName) \($0.day.wake ?? "")" } ?? "Kein Wecker", systemImage: "alarm.fill")
                        .font(.headline).widgetAccentable()
                    if let n = next, !n.detail.isEmpty { Text(n.detail).font(.caption).lineLimit(2).opacity(0.75) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                small(next)
            }
        }
        .containerBackground(for: .widget) {
            if family == .systemSmall {
                LinearGradient(colors: [Color(red: 0.2, green: 0.08, blue: 0.4), Color(red: 0.05, green: 0.03, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else if family == .accessoryCircular { AccessoryWidgetBackground() }
            else { Color.clear }
        }
    }

    private func small(_ next: NextWake?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "alarm.fill").foregroundStyle(hubPurple)
                Text(next?.dayName ?? "Wecker").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
            Text(next?.day.wake ?? "–")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .shadow(color: hubPurple.opacity(0.6), radius: 12)
                .minimumScaleFactor(0.6)
            if let n = next {
                Text(n.detail.isEmpty ? "Schule" : n.detail).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                Text(n.at, style: .relative).font(.caption2).foregroundStyle(.white.opacity(0.45))
            } else {
                Text("Keine Schultage mit Weckzeit").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Watchlist

struct WatchEntry: TimelineEntry {
    let date: Date
    let shows: [WidgetShow]
}

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry { WatchEntry(date: Date(), shows: []) }
    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        completion(WatchEntry(date: Date(), shows: AppGroup.read([WidgetShow].self, "watch.json") ?? []))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        let e = WatchEntry(date: Date(), shows: AppGroup.read([WidgetShow].self, "watch.json") ?? [])
        completion(Timeline(entries: [e], policy: .after(Date().addingTimeInterval(4 * 3600))))
    }
}

struct WatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HubWatch", provider: WatchProvider()) { e in WatchWidgetView(entry: e) }
            .configurationDisplayName("Watchlist")
            .description("Deine Serien mit Fortschritt und neuen Folgen.")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct WatchWidgetView: View {
    let entry: WatchEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if entry.shows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "play.tv.fill").font(.title2).foregroundStyle(hubPurple)
                    Text("Watchlist leer").font(.headline)
                    Text("Öffne Hub, während der PC an ist.").font(.caption).opacity(0.6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if family == .systemLarge {
                list
            } else {
                row
            }
        }
        .foregroundStyle(.white)
        .widgetURL(URL(string: "hubapp://watch"))
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.12, green: 0.06, blue: 0.22), .black], startPoint: .top, endPoint: .bottom)
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(entry.shows.prefix(4).enumerated()), id: \.offset) { _, s in
                VStack(alignment: .leading, spacing: 4) {
                    poster(s).frame(height: 100)
                    Text(s.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Watchlist", systemImage: "play.tv.fill").font(.headline).foregroundStyle(hubPurple)
            ForEach(Array(entry.shows.prefix(5).enumerated()), id: \.offset) { _, s in
                HStack(spacing: 10) {
                    poster(s).frame(width: 38, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(s.title).font(.subheadline.weight(.bold)).lineLimit(1)
                            if s.newEp { Text("NEU").font(.system(size: 9, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 2).background(hubPurple, in: Capsule()) }
                        }
                        if !s.progress.isEmpty { Text(s.progress).font(.caption).opacity(0.6).lineLimit(1) }
                        if let p = s.pct { ProgressView(value: min(1, max(0, p > 1 ? p / 100 : p))).tint(hubPurple) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func poster(_ s: WidgetShow) -> some View {
        ZStack(alignment: .bottom) {
            if let f = s.imageFile, let img = AppGroup.image(f) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.white.opacity(0.1))
                    .overlay(Image(systemName: "film").foregroundStyle(.white.opacity(0.4)))
            }
            if let p = s.pct {
                GeometryReader { g in
                    Rectangle().fill(hubPurple).frame(width: g.size.width * min(1, max(0, p > 1 ? p / 100 : p)), height: 3)
                }
                .frame(height: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if s.newEp { Circle().fill(hubPurple).frame(width: 9, height: 9).padding(4) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
