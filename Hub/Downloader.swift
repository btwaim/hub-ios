import SwiftUI
import UIKit

// Downloader: Link vom Handy → dein Social Media Video Downloader am PC lädt → Datei kommt aufs iPhone (Fotos / Dateien).
// Ohne PC wird der Link gemerkt und automatisch geladen, sobald der Hub erreichbar ist.

struct DLInfo: Decodable {
    struct Height: Decodable, Hashable { let h: Int; let label: String }
    let type: String?
    let platform: String?
    let url: String?
    let title: String?
    let uploader: String?
    let duration: Double?
    let thumbnail: String?
    let heights: [Height]?
    let error: String?
}

struct DLJob: Decodable, Hashable {
    let id: String
    let title: String?
    let kind: String?
    let status: String
    let progress: Double?
    let stage: String?
    let error: String?
}

struct DLItem: Decodable, Hashable {
    let title: String?
    let kind: String?
    let name: String
    let thumbnail: String?
    let size: Double?
    let f: String
}

@MainActor
final class Downloads: ObservableObject {
    static let shared = Downloads()
    @Published var jobs: [DLJob] = []
    @Published var history: [DLItem] = []
    @Published var local: [String: URL] = [:]          // f → Datei auf dem iPhone
    @Published var loadingFile: String?
    @Published var waiting: [String] = UserDefaults.standard.stringArray(forKey: "dlWaiting") ?? [] {
        didSet { UserDefaults.standard.set(waiting, forKey: "dlWaiting") }
    }
    @Published var error: String?
    private var polling = false

    let folder: URL = {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    init() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            local["name:" + name] = folder.appendingPathComponent(name)
        }
    }

    func fileURL(_ item: DLItem) -> URL? { local[item.f] ?? local["name:" + item.name] }

    func info(_ link: String) async -> DLInfo? {
        error = nil
        do {
            let i = try await API.post("/api/dl/info", body: ["url": link], timeout: 120, as: DLInfo.self)
            if let e = i.error { error = e; return nil }
            return i
        } catch {
            self.error = "Hub nicht erreichbar"
            return nil
        }
    }

    func start(url: String, kind: String, height: DLInfo.Height?, title: String?, thumbnail: String?) async {
        error = nil
        var body: [String: Any] = ["url": url, "kind": kind, "title": title ?? "", "thumbnail": thumbnail ?? ""]
        if let h = height { body["height"] = h.h; body["label"] = h.label }
        do {
            let j = try await API.post("/api/dl/start", body: body, timeout: 60, as: DLJob.self)
            jobs.insert(j, at: 0)
            poll()
        } catch {
            self.error = "Konnte den Download nicht starten"
        }
    }

    func poll() {
        guard !polling else { return }
        polling = true
        Task {
            defer { polling = false }
            while jobs.contains(where: { $0.status == "queued" || $0.status == "running" }) {
                try? await Task.sleep(for: .seconds(1.2))
                let ids = jobs.map(\.id).joined(separator: ",")
                guard let fresh = try? await API.get("/api/dl/jobs", ["ids": ids], timeout: 10, as: [DLJob].self) else { continue }
                let wasRunning = Set(jobs.filter { $0.status != "done" }.map(\.id))
                jobs = jobs.map { j in fresh.first { $0.id == j.id } ?? j }
                if jobs.contains(where: { $0.status == "done" && wasRunning.contains($0.id) }) { await loadHistory() }
            }
        }
    }

    func loadHistory() async {
        if let h = try? await API.get("/api/dl/history", timeout: 20, as: [DLItem].self) { history = h }
    }

    /// Gemerkte Links laden (sobald der PC da ist): Video in bester Qualität
    func processWaiting() async {
        guard !waiting.isEmpty else { return }
        for link in waiting {
            guard let i = await info(link) else { continue }
            await start(url: i.url ?? link, kind: "mp4", height: nil, title: i.title, thumbnail: i.thumbnail)
            waiting.removeAll { $0 == link }
        }
    }

    /// Fertige Datei vom PC aufs iPhone holen
    func fetch(_ item: DLItem) async {
        guard let url = Config.url("/dlfile", ["f": item.f]) else { return }
        loadingFile = item.f
        defer { loadingFile = nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 900
        do {
            let (tmp, resp) = try await API.session.download(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { error = "Datei nicht gefunden"; return }
            let dest = folder.appendingPathComponent(item.name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            local[item.f] = dest
        } catch {
            self.error = "Laden fehlgeschlagen"
        }
    }

    /// Video/Bild in die Fotos-App
    func saveToPhotos(_ file: URL) {
        let ext = file.pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(ext), UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(file.path) {
            UISaveVideoAtPathToSavedPhotosAlbum(file.path, nil, nil, nil)
            HubStore.shared.toast = "In Fotos gesichert"
        } else if ["jpg", "jpeg", "png", "webp"].contains(ext), let img = UIImage(contentsOfFile: file.path) {
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            HubStore.shared.toast = "In Fotos gesichert"
        } else {
            error = "Das kann die Fotos-App nicht – über „Teilen“ in Dateien sichern"
        }
    }
}

struct DownloaderView: View {
    @EnvironmentObject var library: Library
    @ObservedObject private var dl = Downloads.shared
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var info: DLInfo?
    @State private var checking = false
    @State private var kind = "mp4"
    @State private var height: DLInfo.Height?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("TikTok-, YouTube-, Insta-Link …", text: $link)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .onSubmit { Task { await check() } }
                        PasteButton(payloadType: String.self) { s in
                            if let first = s.first { link = first.trimmingCharacters(in: .whitespacesAndNewlines); Task { await check() } }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                    }
                    if library.pcOnline {
                        Button { Task { await check() } } label: {
                            HStack { if checking { ProgressView() }; Text(checking ? "Prüfe …" : "Link prüfen") }
                        }
                        .disabled(link.isEmpty || checking)
                    } else {
                        Button {
                            let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !l.isEmpty && !dl.waiting.contains(l) { dl.waiting.append(l) }
                            link = ""
                        } label: { Label("Merken – lädt, sobald der PC an ist", systemImage: "clock.arrow.circlepath") }
                        .disabled(link.isEmpty)
                    }
                    if let e = dl.error { Text(e).font(.footnote).foregroundStyle(.red) }
                } footer: {
                    Text("Dein Downloader am PC lädt die Datei, danach holst du sie hier aufs iPhone.")
                }

                if let i = info { infoSection(i) }

                if !dl.waiting.isEmpty {
                    Section("Wartet auf den PC") {
                        ForEach(dl.waiting, id: \.self) { l in Text(l).font(.footnote).lineLimit(1) }
                            .onDelete { dl.waiting.remove(atOffsets: $0) }
                    }
                }

                let active = dl.jobs.filter { $0.status != "done" }
                if !active.isEmpty {
                    Section("Läuft") {
                        ForEach(active, id: \.id) { j in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(j.title ?? "Download").font(.subheadline.weight(.semibold)).lineLimit(1)
                                if j.status == "error" {
                                    Text(j.error ?? "Fehler").font(.caption).foregroundStyle(.red)
                                } else {
                                    ProgressView(value: j.progress ?? 0).tint(.purple)
                                    Text(j.stage ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !dl.history.isEmpty {
                    Section("Fertig am PC") {
                        ForEach(dl.history, id: \.f) { item in historyRow(item) }
                    }
                }
            }
            .navigationTitle("Downloader")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Fertig") { dismiss() } }
            }
            .refreshable { await dl.loadHistory() }
            .task {
                if library.pcOnline {
                    await dl.processWaiting()
                    await dl.loadHistory()
                }
            }
        }
    }

    private func check() async {
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return }
        checking = true
        defer { checking = false }
        info = await dl.info(l)
        height = info?.heights?.first
        kind = "mp4"
    }

    @ViewBuilder private func infoSection(_ i: DLInfo) -> some View {
        Section {
            HStack(spacing: 12) {
                RemoteImage(url: i.thumbnail, icon: "play.rectangle")
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(i.title ?? "Video").font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text([i.platform, i.uploader, i.duration.map { formatTime($0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Picker("Art", selection: $kind) {
                Text("Video").tag("mp4")
                Text("MP3").tag("mp3")
                Text("Bild").tag("thumb")
            }
            .pickerStyle(.segmented)
            if kind == "mp4", let hs = i.heights, !hs.isEmpty {
                Picker("Qualität", selection: $height) {
                    ForEach(hs, id: \.self) { h in Text(h.label).tag(Optional(h)) }
                }
            }
            Button {
                let target = i
                Task {
                    await dl.start(url: target.url ?? link, kind: kind, height: kind == "mp4" ? height : nil, title: target.title, thumbnail: target.thumbnail)
                    info = nil
                    link = ""
                }
            } label: {
                Label("Herunterladen", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func historyRow(_ item: DLItem) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: item.thumbnail, icon: item.kind == "mp3" ? "music.note" : "film")
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([item.kind?.uppercased(), item.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let file = dl.fileURL(item) {
                Menu {
                    ShareLink(item: file) { Label("Teilen / In Dateien sichern", systemImage: "square.and.arrow.up") }
                    Button { dl.saveToPhotos(file) } label: { Label("In Fotos sichern", systemImage: "photo.on.rectangle") }
                } label: {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                }
            } else if dl.loadingFile == item.f {
                ProgressView()
            } else {
                Button { Task { await dl.fetch(item) } } label: { Image(systemName: "icloud.and.arrow.down").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.purple)
                    .disabled(!library.pcOnline)
            }
        }
    }
}
