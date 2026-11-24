import Foundation
import SwiftUI

/// Kalender, Watchlist und Gaming aus dem Hub (offline zwischengespeichert)
struct HubData: Codable {
    struct Event: Codable, Hashable {
        let id: String?
        let title: String
        let type: String
        let date: String
        let time: String?
        let when: String
        let mine: Bool?
    }
    struct Media: Codable, Hashable {
        let id: String
        let title: String
        let image: String?
        let type: String?
        var status: String
        var progress: String
        var pct: Double?
        var newEp: Int?
    }
    struct Boss: Codable, Hashable {
        let id: String
        let name: String
        var defeated: Bool
        var deaths: Int
    }
    struct Game: Codable, Hashable {
        let id: String
        let name: String
        let image: String?
        let status: String?
        var deaths: Int
        let counts: Bool?
        var bossId: String?
        var bosses: [Boss]
        let lastPlayed: Double?

        var currentBoss: Boss? { bosses.first { $0.id == bossId && !$0.defeated } }
        var shownDeaths: Int { currentBoss?.deaths ?? deaths }
    }
    struct Lamp: Codable, Hashable { let id: String; let name: String; let ip: String; let mine: Bool? }
    var events: [Event]
    var media: [Media]
    var games: [Game]
    var active: String?
    var lamps: [Lamp]?

    var activeGame: Game? { games.first { $0.id == active } }
}

@MainActor
final class HubStore: ObservableObject {
    static let shared = HubStore()
    @Published private(set) var data: HubData? = Store.load(HubData.self, "hubdata.json")
    @Published var toast: String?
    @Published private(set) var queued = 0
    private var queue: [Data] = Store.load([Data].self, "hubqueue.json") ?? []
    private var flushing = false

    init() { queued = queue.count }

    func refresh() async {
        guard Config.isSetUp else { return }
        await flush()
        if let d = try? await API.get("/api/hub", timeout: 8, as: HubData.self) {
            data = d
            Store.save(d, "hubdata.json")
        }
    }

    /// Aktion an den Hub schicken. Ohne PC wird sie gemerkt und später nachgereicht; die Anzeige ändert sich sofort.
    func act(_ body: [String: Any], _ optimistic: ((inout HubData) -> Void)? = nil) {
        if var d = data, let f = optimistic {
            f(&d)
            data = d
            Store.save(d, "hubdata.json")
        }
        guard let json = try? JSONSerialization.data(withJSONObject: body) else { return }
        queue.append(json)
        save()
        Task {
            await flush()
            if queue.isEmpty, let d = try? await API.get("/api/hub", timeout: 8, as: HubData.self) {
                data = d
                Store.save(d, "hubdata.json")
            }
        }
    }

    func flush() async {
        guard !flushing, !queue.isEmpty else { return }
        flushing = true
        defer { flushing = false; save() }
        struct Reply: Decodable { let msg: String?; let error: String? }
        while let first = queue.first {
            guard let obj = (try? JSONSerialization.jsonObject(with: first)) as? [String: Any] else { queue.removeFirst(); continue }
            guard let r = try? await API.post("/api/action", body: obj, as: Reply.self) else { break }   // PC nicht da → später
            queue.removeFirst()
            if let m = r.msg, !m.isEmpty { toast = m }
        }
    }

    private func save() {
        Store.save(queue, "hubqueue.json")
        queued = queue.count
    }
}

// MARK: - Hilfen

/// Bild aus dem Netz, einmal geladen → offline
struct RemoteImage: View {
    let url: String?
    var icon = "photo"
    @State private var image: UIImage?

    var body: some View {
        // Bild als Overlay: nimmt genau den angebotenen Platz ein und wird zugeschnitten (bläht das Layout nie auf)
        Rectangle().fill(Color.white.opacity(0.07))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: icon).foregroundStyle(.white.opacity(0.3))
                }
            }
            .clipped()
            .task(id: url) {
                let u = url
                let img = await CoverCache.shared.image(for: u, px: 500)
                guard !Task.isCancelled, u == url else { return }
                image = img
            }
    }
}

/// „14 / 25 Folgen“ → erste Zahl um d ändern (sofortige Anzeige, der Hub liefert danach den echten Stand)
func bumpLabel(_ m: inout HubData.Media, _ d: Int) {
    let s = m.progress
    guard let r = s.range(of: "\\d+", options: .regularExpression), let n = Int(s[r]) else { return }
    let v = max(0, n + d)
    m.progress = s.replacingCharacters(in: r, with: String(v))
    let rest = s[r.upperBound...]
    if let r2 = rest.range(of: "\\d+", options: .regularExpression), let total = Double(rest[r2]), total > 0 {
        m.pct = min(100, Double(v) / total * 100)
    }
    if let e = m.newEp, e > 0 { m.newEp = max(0, e - d) }
}

func dayTitle(_ iso: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    guard let d = f.date(from: iso) else { return iso }
    let c = Calendar.current
    if c.isDateInToday(d) { return "Heute" }
    if c.isDateInTomorrow(d) { return "Morgen" }
    let o = DateFormatter()
    o.locale = Locale(identifier: "de_DE")
    let days = c.dateComponents([.day], from: c.startOfDay(for: Date()), to: d).day ?? 99
    o.dateFormat = days < 7 ? "EEEE" : "EEEE, d. MMMM"
    return o.string(from: d)
}

func eventStyle(_ type: String) -> (icon: String, color: Color) {
    let t = type.lowercased()
    if t.contains("exam") || t.contains("arbeit") || t.contains("klausur") { return ("doc.text.fill", .red) }
    if t.contains("home") || t.contains("haus") { return ("book.closed.fill", .orange) }
    if t.contains("birth") || t.contains("geburt") { return ("gift.fill", .pink) }
    if t.contains("ferien") || t.contains("holiday") || t.contains("frei") { return ("sun.max.fill", .yellow) }
    return ("calendar", .purple)
}

/// Glas-Karte im iOS-26-Stil
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

struct CardTitle: View {
    let text: String
    let icon: String
    var color: Color = .purple
    var body: some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(color)
    }
}

/// kurze Meldung oben (z. B. „+1 eingetragen“)
struct ToastOverlay: View {
    @EnvironmentObject var hub: HubStore
    var body: some View {
        VStack {
            if let t = hub.toast {
                Text(t)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: t) {
                        try? await Task.sleep(for: .seconds(2.2))
                        withAnimation { hub.toast = nil }
                    }
            }
            Spacer()
        }
        .padding(.top, 6)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hub.toast)
        .allowsHitTesting(false)
    }
}
