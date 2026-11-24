import Foundation
import ActivityKit
import WidgetKit
import UIKit

/// Live Activity: Song + aktuelle Lyrics-Zeile auf dem Sperrbildschirm und in der Dynamic Island
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private var activity: Activity<NowPlayingAttributes>?
    private var last: NowPlayingAttributes.ContentState?

    func update(_ state: NowPlayingAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if state == last { return }
        last = state
        let content = ActivityContent(state: state, staleDate: nil)
        if let a = activity ?? Activity<NowPlayingAttributes>.activities.first, a.activityState == .active {
            activity = a
            Task { await a.update(content) }
        } else {
            activity = try? Activity.request(attributes: NowPlayingAttributes(), content: content, pushType: nil)
        }
    }

    func end() {
        last = nil
        let all = Activity<NowPlayingAttributes>.activities
        Task { for a in all { await a.end(nil, dismissalPolicy: .immediate) } }
        activity = nil
    }
}

/// Daten für die Home- und Sperrbildschirm-Widgets (liegen in der App Group)
enum WidgetData {
    static func writeNowPlaying(_ n: WidgetNowPlaying?) {
        if let n { AppGroup.write(n, "nowplaying.json") }
        else if let dir = AppGroup.container { try? FileManager.default.removeItem(at: dir.appendingPathComponent("nowplaying.json")) }
        WidgetCenter.shared.reloadTimelines(ofKind: "HubNowPlaying")
        WidgetCenter.shared.reloadTimelines(ofKind: "HubLyrics")
    }

    static func writeWake(_ days: [WakeDay]) {
        AppGroup.write(days.map { WidgetDay(date: $0.date, free: $0.free, wake: $0.wake, label: $0.label ?? "", period: $0.period, subject: $0.subject) }, "wake.json")
        WidgetCenter.shared.reloadTimelines(ofKind: "HubWake")
    }

    static func writeWatch(_ shows: [HubState.Show]) {
        Task {
            var out: [WidgetShow] = []
            for s in shows.prefix(6) {
                var file: String?
                if let img = s.image, let url = URL(string: img), let dir = AppGroup.container {
                    let name = "show-\(s.id).jpg"
                    let target = dir.appendingPathComponent(name)
                    if !FileManager.default.fileExists(atPath: target.path),
                       let (data, _) = try? await URLSession.shared.data(from: url), let im = UIImage(data: data) {
                        let size = CGSize(width: 180, height: 270)
                        let small = UIGraphicsImageRenderer(size: size).image { _ in im.draw(in: CGRect(origin: .zero, size: size)) }
                        try? small.jpegData(compressionQuality: 0.8)?.write(to: target)
                    }
                    if FileManager.default.fileExists(atPath: target.path) { file = name }
                }
                out.append(WidgetShow(title: s.title, progress: s.progress ?? "", pct: s.pct, newEp: s.newEp ?? false, imageFile: file))
            }
            AppGroup.write(out, "watch.json")
            WidgetCenter.shared.reloadTimelines(ofKind: "HubWatch")
        }
    }
}
