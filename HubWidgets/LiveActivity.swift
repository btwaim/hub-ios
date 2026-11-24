import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

// MARK: - Bausteine

let hubPurple = Color(red: 0.66, green: 0.45, blue: 1.0)

func clock(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let t = Int(s)
    return String(format: "%d:%02d", t / 60, t % 60)
}

struct CoverThumb: View {
    let file: String?
    var size: CGFloat
    var corner: CGFloat

    var body: some View {
        Group {
            if let f = file, let img = AppGroup.image(f) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [hubPurple, Color(red: 0.25, green: 0.1, blue: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Unscharfes Cover als Hintergrund
struct CoverGlow: View {
    let file: String?
    var dim: Double = 0.45

    var body: some View {
        ZStack {
            Color.black
            if let f = file, let img = AppGroup.image(f) {
                Image(uiImage: img).resizable().scaledToFill()
                    .blur(radius: 28)
                    .saturation(1.5)
                    .opacity(0.9)
            } else {
                LinearGradient(colors: [Color(red: 0.22, green: 0.08, blue: 0.42), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Color.black.opacity(dim)
        }
    }
}

/// Lyrics-Zeile mit Leuchten wie im Hub
struct GlowLine: View {
    let text: String
    var size: CGFloat = 17
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .heavy))
            .foregroundStyle(.white)
            .shadow(color: .white.opacity(0.55), radius: 6)
            .shadow(color: hubPurple.opacity(0.6), radius: 14)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
    }
}

struct ProgressRow: View {
    let state: NowPlayingAttributes.ContentState
    var showTimes = true

    var body: some View {
        HStack(spacing: 8) {
            if showTimes { elapsed.frame(width: 38, alignment: .leading) }
            if let r = state.range {
                ProgressView(timerInterval: r, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
                    .tint(.white)
            } else {
                ProgressView(value: state.pausedProgress).tint(.white.opacity(0.7))
            }
            if showTimes { remaining.frame(width: 44, alignment: .trailing) }
        }
        .font(.caption2.monospacedDigit().weight(.semibold))
        .foregroundStyle(.white.opacity(0.65))
    }

    @ViewBuilder private var elapsed: some View {
        if let r = state.range { Text(timerInterval: r, countsDown: false).multilineTextAlignment(.leading) }
        else { Text(clock(state.elapsed)) }
    }
    @ViewBuilder private var remaining: some View {
        if let r = state.range { Text(timerInterval: r, countsDown: true).multilineTextAlignment(.trailing) }
        else { Text("-" + clock(max(0, state.duration - state.elapsed))) }
    }
}

struct Controls: View {
    let isPlaying: Bool
    var size: CGFloat = 20
    var spacing: CGFloat = 22

    var body: some View {
        HStack(spacing: spacing) {
            Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill").font(.system(size: size * 0.8)) }
            Button(intent: TogglePlayIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: size))
                    .contentTransition(.symbolEffect(.replace))
            }
            Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill").font(.system(size: size * 0.8)) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

/// kleine „Equalizer“-Balken (statisch, Höhe nach Zustand)
struct Bars: View {
    let playing: Bool
    var color: Color = hubPurple
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach([0.55, 1.0, 0.7, 0.9], id: \.self) { h in
                Capsule().fill(color).frame(width: 3, height: playing ? 14 * h : 4)
            }
        }
        .frame(height: 14, alignment: .bottom)
    }
}

// MARK: - Live Activity

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            LockScreenActivity(state: context.state)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "hubapp://player"))
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CoverThumb(file: s.coverFile, size: 58, corner: 14)
                        .shadow(color: hubPurple.opacity(0.5), radius: 10)
                        .padding(.leading, 4).padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 6) {
                        Bars(playing: s.isPlaying)
                        if !s.fx.isEmpty {
                            Text(s.fx).font(.caption2.weight(.bold)).foregroundStyle(hubPurple).lineLimit(1)
                        }
                    }
                    .padding(.trailing, 6).padding(.top, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(.headline).lineLimit(1)
                        Text(s.artist).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        if !s.lyric.isEmpty {
                            GlowLine(text: s.lyric, size: 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.push(from: .bottom))
                                .id(s.lyric)
                        }
                        ProgressRow(state: s)
                        Controls(isPlaying: s.isPlaying, size: 24, spacing: 44)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                CoverThumb(file: s.coverFile, size: 24, corner: 7)
            } compactTrailing: {
                Bars(playing: s.isPlaying)
            } minimal: {
                CoverThumb(file: s.coverFile, size: 22, corner: 11)
            }
            .keylineTint(hubPurple)
            .widgetURL(URL(string: "hubapp://player"))
        }
    }
}

struct LockScreenActivity: View {
    let state: NowPlayingAttributes.ContentState

    var body: some View {
        // Den Player (Cover, Knöpfe, Fortschritt) zeigt Apple selbst darunter – hier nur das, was Apple nicht kann:
        // die mitlaufenden Lyrics mit Leuchten wie am PC
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Bars(playing: state.isPlaying, color: .white.opacity(0.75))
                Text(state.title).font(.caption.weight(.bold)).lineLimit(1)
                Text(state.artist).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                Spacer(minLength: 0)
                if !state.fx.isEmpty { Text(state.fx).font(.caption2.weight(.heavy)).foregroundStyle(hubPurple).lineLimit(1) }
            }
            if !state.lyric.isEmpty {
                GlowLine(text: state.lyric, size: 21)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.push(from: .bottom))
                    .id(state.lyric)
                if !state.nextLyric.isEmpty {
                    Text(state.nextLyric).font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                        .blur(radius: 0.4)
                }
            } else {
                Text(state.isPlaying ? "♪ ♪ ♪" : "Pausiert")
                    .font(.system(size: 19, weight: .heavy)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background { CoverGlow(file: state.coverFile, dim: 0.55) }
    }
}
