import SwiftUI
import WebKit
import UIKit

// Ashen Oath – das Spiel zu deinen Songs. Läuft als Web-Spiel (dasselbe wie am PC) in einer WKWebView:
// hubgame://app/… liefert die Spieldateien aus dem App-Paket, hubgame://song/… deine offline gespeicherten Songs,
// hubgame://stream/<id> alle anderen Songs direkt vom PC (mit Hub-Sound, wie im Musik-Tab).
// Spielstand (Gold, Ritter, Schmiede) wird mit dem PC zusammengeführt, sobald er erreichbar ist.

struct GameScreen: View {
    @EnvironmentObject var nav: Nav

    var body: some View {
        GameWebView { nav.showGame = false }
            .ignoresSafeArea()
            .background(Color.black)
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
    }
}

struct GameWebView: UIViewRepresentable {
    var onClose: () -> Void

    func makeCoordinator() -> GameBridge { GameBridge(onClose: onClose) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(GameScheme(), forURLScheme: "hubgame")
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "host")
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isInspectable = true
        var url = "hubgame://app/index.html"
        if Demo.screen == "game" { url += "?demo=1" }
        web.load(URLRequest(url: URL(string: url)!))
        context.coordinator.web = web
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator: GameBridge) {
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.stopLoading()
    }
}

/// Liefert Spieldateien und Songs über ein eigenes Schema (gleicher Ursprung → Module/Audio ohne Sperren)
final class GameScheme: NSObject, WKURLSchemeHandler {
    private var stopped = Set<ObjectIdentifier>()
    private static let streamCache: NSCache<NSString, NSData> = { let c = NSCache<NSString, NSData>(); c.totalCostLimit = 80_000_000; return c }()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        if url.host == "stream" { stream(url, task); return }
        var file: URL?
        if url.host == "app", let root = Bundle.main.url(forResource: "Game", withExtension: nil) {
            let rel = url.path.isEmpty || url.path == "/" ? "index.html" : String(url.path.dropFirst())
            let f = root.appendingPathComponent(rel).standardizedFileURL
            if f.path.hasPrefix(root.standardizedFileURL.path) { file = f }   // nicht aus dem Spielordner heraus
        } else if url.host == "song" {
            let name = url.lastPathComponent
            if !name.contains("/") && !name.hasPrefix(".") { file = Store.dir("Songs").appendingPathComponent(name) }
        }
        guard let f = file, let data = try? Data(contentsOf: f) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        respond(task, url, data, f.pathExtension.lowercased())
    }

    private func respond(_ task: WKURLSchemeTask, _ url: URL, _ data: Data, _ ext: String) {
        let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "json": "application/json", "m4a": "audio/mp4", "mp3": "audio/mpeg", "png": "image/png"]
        let mime = types[ext] ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-cache"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { stopped.insert(ObjectIdentifier(task)) }

    /// Song vom PC holen (gleiche Adresse wie das Streamen im Musik-Tab), zwischengespeichert für Menü-Musik + Runde
    private func stream(_ url: URL, _ task: WKURLSchemeTask) {
        let id = url.lastPathComponent
        if let d = Self.streamCache.object(forKey: id as NSString) { respond(task, url, d as Data, "m4a"); return }
        let remote: URL? = MainActor.assumeIsolated {
            let lib = Library.shared
            return lib.tracks.first { $0.id == id }.flatMap { lib.streamURL($0) }
        }
        guard let remote else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        var req = URLRequest(url: remote)
        req.timeoutInterval = 120
        let key = ObjectIdentifier(task)
        API.session.dataTask(with: req) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                guard let self, !self.stopped.contains(key) else { return }
                if let data, (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                    Self.streamCache.setObject(data as NSData, forKey: id as NSString, cost: data.count)
                    self.respond(task, url, data, "m4a")
                } else {
                    task.didFailWithError(URLError(.cannotLoadFromNetwork))
                }
            }
        }.resume()
    }
}

/// Nachrichten vom Spiel (window.webkit.messageHandlers.host.postMessage) mit Antwort
@MainActor
final class GameBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var web: WKWebView?
    let onClose: () -> Void
    private let saveFile = Store.support.appendingPathComponent("ashen-oath.json")

    init(onClose: @escaping () -> Void) { self.onClose = onClose }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return (nil, "ungültig") }
        switch type {
        case "songs": return (Self.json(songs()), nil)
        case "load": return ((try? String(contentsOf: saveFile, encoding: .utf8)) ?? "null", nil)
        case "sync": return (await sync(body["save"]), nil)
        case "haptic": Self.haptic(body["kind"] as? String ?? "light"); return (true, nil)
        case "pauseHub": if Player.shared.isPlaying { Player.shared.toggle() }; return (true, nil)
        case "close": onClose(); return (true, nil)
        default: return (nil, nil)
        }
    }

    /// offline gespeicherte Songs (schon im Hub-Sound) – Main = deine Rotation
    private func songs() -> [[String: Any]] {
        let lib = Library.shared
        // offline gespeicherte direkt vom Handy, alle anderen vom PC (wenn erreichbar)
        return lib.tracks.compactMap { t in
            var d: [String: Any] = ["id": t.id, "title": t.title, "artist": t.artist, "main": t.main ?? false, "duration": t.duration ?? 0, "baked": true]
            if let local = lib.localFile(t) { d["url"] = "hubgame://song/\(local.url.lastPathComponent)"; d["offline"] = true }
            else if lib.pcOnline { d["url"] = "hubgame://stream/\(t.id)"; d["offline"] = false }
            else { return nil }
            return d
        }
    }

    /// Spielstand sichern und mit dem PC zusammenführen (der PC rechnet, das iPhone merkt sich das Ergebnis)
    private func sync(_ save: Any?) async -> String {
        guard let save, JSONSerialization.isValidJSONObject(save), let local = try? JSONSerialization.data(withJSONObject: save) else { return "null" }
        try? local.write(to: saveFile, options: .atomic)
        guard let url = Config.url("/api/game"), let body = try? JSONSerialization.data(withJSONObject: ["save": save]) else {
            return String(data: local, encoding: .utf8) ?? "null"
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        r.timeoutInterval = 5
        if let (data, resp) = try? await API.session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["error"] == nil {
            try? data.write(to: saveFile, options: .atomic)
            return String(data: data, encoding: .utf8) ?? "null"
        }
        return String(data: local, encoding: .utf8) ?? "null"
    }

    static func json(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v) else { return "null" }
        return String(data: d, encoding: .utf8) ?? "null"
    }

    static func haptic(_ kind: String) {
        switch kind {
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        default: UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
        }
    }
}

/// Großes Banner zum Spiel (Musik- und Gaming-Seite)
struct GameBanner: View {
    @EnvironmentObject var nav: Nav

    var body: some View {
        Button { nav.showGame = true } label: {
            HStack(spacing: 14) {
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.76, green: 0.16, blue: 0.23), Color(red: 0.42, green: 0.05, blue: 0.09)], center: .init(x: 0.4, y: 0.4), startRadius: 2, endRadius: 26))
                    .frame(width: 44, height: 44)
                    .shadow(color: Color(red: 1, green: 0.16, blue: 0.23).opacity(0.6), radius: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ASHEN OATH")
                        .font(.system(size: 19, weight: .black, design: .serif))
                        .tracking(2)
                        .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.95, blue: 0.75), Color(red: 1, green: 0.54, blue: 0.24), Color(red: 0.76, green: 0.16, blue: 0.1)], startPoint: .top, endPoint: .bottom))
                    Text("Roguelike zu deinen Songs · Bosse im Takt").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 4)
                Image(systemName: "play.fill").font(.headline).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(Color(red: 0.8, green: 0.25, blue: 0.15), in: Circle())
            }
            .padding(14)
            .background(
                RadialGradient(colors: [Color(red: 0.29, green: 0.06, blue: 0.1), Color(red: 0.1, green: 0.04, blue: 0.06), Color(red: 0.04, green: 0.03, blue: 0.06)], center: .init(x: 0.85, y: 0.2), startRadius: 4, endRadius: 260),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color(red: 0.4, green: 0.12, blue: 0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
