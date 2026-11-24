import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// Wiedergabe: offline aus dem Speicher (oder vom PC gestreamt), im Hintergrund, Sperrbildschirm, Dynamic Island, Widgets.
@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    enum Repeat: Int { case off, all, one }
    enum Sleep: Equatable { case off, minutes(Int), endOfSong }

    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false {
        didSet { if oldValue != isPlaying { playStateChanged() } }
    }
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    /// Tempo, das schon in der gespielten Datei steckt (für die Lyrics-Zeit)
    @Published private(set) var bakedRate: Double = 1
    @Published private(set) var lyricIndex: Int?
    @Published var shuffle: Bool = UserDefaults.standard.bool(forKey: "shuffle") {
        didSet { UserDefaults.standard.set(shuffle, forKey: "shuffle"); rebuildOrder(keep: current) }
    }
    @Published var repeatMode: Repeat = Repeat(rawValue: UserDefaults.standard.integer(forKey: "repeat")) ?? .all {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeat") }
    }
    @Published var spatial: Bool = UserDefaults.standard.bool(forKey: "spatial") {
        didSet { UserDefaults.standard.set(spatial, forKey: "spatial"); applySpatial() }
    }
    /// Lyrics auf dem Sperrbildschirm + Dynamic Island (Live-Aktivität)
    @Published var liveLyrics: Bool = UserDefaults.standard.object(forKey: "liveLyrics") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(liveLyrics, forKey: "liveLyrics")
            if liveLyrics { pushSurfaces(track: true) } else { LiveActivityManager.shared.end() }
        }
    }
    @Published private(set) var sleep: Sleep = .off
    @Published private(set) var sleepEnds: Date?
    @Published var message: String?

    weak var library: Library?
    weak var lyrics: Lyrics?
    private let player = AVPlayer()
    private let bass = BassProcessor()
    private var baked = Fx(rate: 1, bass: 0, reverb: false)
    private var playingFile: String?
    private var ratio: Double = 1
    private var order: [String] = []
    private var timeObserver: Any?
    private var observers: [NSObjectProtocol] = []
    private var artwork: MPMediaItemArtwork?
    private var thumbFile: String?
    private var resumeAfterRoute = false
    private var ticks = 0
    private let keepAlive = KeepAlive()
    private var idleEnd: Task<Void, Never>?
    /// So lange bleiben Sperrbildschirm-Lyrics + Dynamic Island nach dem Pausieren stehen
    static let idleSeconds: Double = 180

    /// Pause → nach 3 Minuten ohne Musik verschwinden Lyrics-Anzeige und Dynamic Island.
    /// Die App bleibt dafür so lange wach (stilles Audio), sonst würde iOS sie vorher einfrieren.
    private func playStateChanged() {
        idleEnd?.cancel()
        if isPlaying {
            keepAlive.stop()
            return
        }
        guard current != nil else { return }
        keepAlive.start()
        idleEnd = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Player.idleSeconds))
            guard let self, !Task.isCancelled, !self.isPlaying else { return }
            LiveActivityManager.shared.end()
            self.keepAlive.stop()
        }
    }

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        })
        // AirPods raus = Pause, wieder rein = weiter
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.routeChanged(raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))) }
        })
        // Anrufe / andere Unterbrechungen
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            MainActor.assumeIsolated { self?.interrupted(type, resume: AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume)) }
        })
        setupRemote()
        HubControl.shared.handler = { [weak self] cmd in
            switch cmd {
            case "toggle": self?.toggle()
            case "next": self?.next()
            case "prev": self?.previous()
            default: break
            }
        }
    }

    private var tracks: [Track] { library?.tracks ?? [] }

    // MARK: Steuerung

    func play(_ t: Track, at start: Double = 0) {
        guard let lib = library else { return }
        let url: URL
        let fx: Fx
        if let local = lib.localFile(t) {
            url = local.url; fx = local.baked
        } else if lib.pcOnline, let remote = lib.streamURL(t) {
            url = remote; fx = t.fx ?? Fx(rate: 1, bass: 0, reverb: false)
        } else {
            message = "„\(t.title)“ ist noch nicht offline gespeichert"
            return
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        current = t
        baked = fx
        playingFile = url.isFileURL ? url.lastPathComponent : t.fileName
        if !order.contains(t.id) { rebuildOrder(keep: t) }
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .varispeed          // Tempo + Tonhöhe zusammen (wie „sped up“ im Hub)
        item.allowedAudioSpatializationFormats = spatial ? .monoStereoAndMultichannel : .multichannel
        player.replaceCurrentItem(with: item)
        applyLiveFx()
        Task { await AudioTap.attach(bass, to: item) }
        if start > 0 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
        player.playImmediately(atRate: Float(ratio))
        isPlaying = true
        time = start
        duration = (t.duration ?? 0) / 1000 / max(fx.rate ?? 1, 0.1)
        lyricIndex = nil
        UserDefaults.standard.set(t.id, forKey: "lastTrack")
        loadArtwork(t)
        Task { await lyrics?.load(t); pushSurfaces(track: true) }
        updateNowPlaying()
        pushSurfaces(track: true)
    }

    func toggle() {
        if current == nil {
            if let first = firstToPlay() { play(first) }
            return
        }
        if isPlaying { player.pause(); isPlaying = false }
        else {
            try? AVAudioSession.sharedInstance().setActive(true)
            if player.currentItem == nil, let c = current { play(c); return }
            player.playImmediately(atRate: Float(ratio)); isPlaying = true
        }
        updateNowPlaying()
        pushSurfaces(track: true)
    }

    func next() { step(1) }
    func previous() {
        if time > 3 { seek(to: 0) } else { step(-1) }
    }
    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        time = seconds
        updateNowPlaying()
        pushSurfaces(track: true)
    }

    func setSleep(_ s: Sleep) {
        sleep = s
        if case .minutes(let m) = s { sleepEnds = Date().addingTimeInterval(Double(m) * 60) } else { sleepEnds = nil }
    }

    // MARK: Effekte (sofort hörbar, der PC rechnet danach exakt nach)

    func setFx(_ fx: Fx) {
        guard let t = current else { return }
        library?.setFx(t, fx)
        applyLiveFx()
    }

    var currentFx: Fx { current.flatMap { library?.desiredFx($0) } ?? Fx(rate: 1, bass: 0, reverb: false) }
    /// Hall lässt sich nicht live dazurechnen – kommt mit der exakten Fassung vom PC
    var reverbPending: Bool { (currentFx.reverb ?? false) != (baked.reverb ?? false) }

    private func applyLiveFx() {
        guard let t = current, let lib = library else { return }
        let want = lib.desiredFx(t)
        ratio = (want.rate ?? 1) / max(baked.rate ?? 1, 0.1)
        bass.delta = (want.bass ?? 0) - (baked.bass ?? 0)
        bakedRate = baked.rate ?? 1
        player.defaultRate = Float(ratio)
        if isPlaying { player.rate = Float(ratio) }
        updateNowPlaying()
        pushSurfaces(track: true)
    }

    private func applySpatial() {
        player.currentItem?.allowedAudioSpatializationFormats = spatial ? .monoStereoAndMultichannel : .multichannel
    }

    /// Hat der PC inzwischen die exakte Fassung geliefert? → nahtlos wechseln (gleiche Stelle)
    private func checkUpgrade() {
        guard let c = current, let lib = library, let fresh = lib.tracks.first(where: { $0.id == c.id }),
              let local = lib.localFile(fresh), local.url.lastPathComponent != playingFile,
              local.url.lastPathComponent == fresh.fileName else { return }
        let pos = time * (baked.rate ?? 1) / max(local.baked.rate ?? 1, 0.1)
        let wasPlaying = isPlaying
        play(fresh, at: pos)
        if !wasPlaying { player.pause(); isPlaying = false; updateNowPlaying() }
    }

    // MARK: Reihenfolge

    private func firstToPlay() -> Track? {
        if let last = UserDefaults.standard.string(forKey: "lastTrack"), let t = tracks.first(where: { $0.id == last }) { return t }
        rebuildOrder(keep: nil)
        return order.first.flatMap { id in tracks.first { $0.id == id } }
    }

    private func rebuildOrder(keep: Track?) {
        var ids = tracks.map(\.id)
        if shuffle {
            ids.shuffle()
            if let k = keep?.id, let i = ids.firstIndex(of: k) { ids.remove(at: i); ids.insert(k, at: 0) }
        }
        order = ids
    }

    private func step(_ dir: Int) {
        guard !tracks.isEmpty else { return }
        if order.count != tracks.count { rebuildOrder(keep: current) }
        let i = current.flatMap { c in order.firstIndex(of: c.id) } ?? -1
        for k in 1...order.count {
            let j = ((i + dir * k) % order.count + order.count) % order.count
            if let t = tracks.first(where: { $0.id == order[j] }), library?.isOffline(t) == true || library?.pcOnline == true {
                play(t)
                return
            }
        }
    }

    private func finished() {
        if sleep == .endOfSong {
            setSleep(.off)
            player.pause(); isPlaying = false
            seek(to: 0)
            return
        }
        if repeatMode == .one { seek(to: 0); player.playImmediately(atRate: Float(ratio)); return }
        step(1)
    }

    private func tick(_ seconds: Double) {
        if seconds.isFinite { time = seconds }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        if let end = sleepEnds, Date() >= end { fadeOutAndStop() }
        // aktuelle Lyrics-Zeile → Dynamic Island / Sperrbildschirm
        if let l = lyrics, l.trackID == current?.id {
            let idx = l.index(at: time, rate: bakedRate)
            if idx != lyricIndex { lyricIndex = idx; pushSurfaces(track: false) }
        }
        ticks += 1
        if ticks % 8 == 0 { checkUpgrade() }
    }

    private func fadeOutAndStop() {
        sleepEnds = nil
        sleep = .off
        Task { @MainActor in
            for k in stride(from: 1.0, through: 0, by: -0.05) {
                player.volume = Float(k)
                try? await Task.sleep(for: .milliseconds(150))
            }
            player.pause(); isPlaying = false
            player.volume = 1
            updateNowPlaying()
            pushSurfaces(track: true)
        }
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        switch reason {
        case .oldDeviceUnavailable:
            if isPlaying { player.pause(); isPlaying = false; resumeAfterRoute = true; updateNowPlaying(); pushSurfaces(track: true) }
        case .newDeviceAvailable:
            if resumeAfterRoute { resumeAfterRoute = false; toggle() }
        default: break
        }
    }

    private func interrupted(_ type: AVAudioSession.InterruptionType?, resume: Bool) {
        if type == .began { isPlaying = false; pushSurfaces(track: true) }
        else if type == .ended, resume, current != nil { player.playImmediately(atRate: Float(ratio)); isPlaying = true; pushSurfaces(track: true) }
    }

    // MARK: Sperrbildschirm / Kopfhörer

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { if self?.isPlaying == false { self?.toggle() } }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { if self?.isPlaying == true { self?.toggle() } }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func loadArtwork(_ t: Track) {
        artwork = nil
        thumbFile = nil
        Task { @MainActor in
            var found = await ArtStore.shared.image(for: t, allowNetwork: library?.pcOnline ?? false)
            if found == nil { found = await CoverCache.shared.image(for: t.cover) }
            guard let img = found, current?.id == t.id else { return }
            artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            updateNowPlaying()
            thumbFile = await ArtStore.shared.exportThumb(t)
            pushSurfaces(track: true)
        }
    }

    private func updateNowPlaying() {
        guard let t = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: currentFx.label.isEmpty ? "Hub" : "Hub · \(currentFx.label)",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? ratio : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: ratio,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Live Activity + Widgets aktualisieren
    private func pushSurfaces(track: Bool) {
        guard let t = current else { LiveActivityManager.shared.end(); WidgetData.writeNowPlaying(nil); return }
        let lines = (lyrics?.trackID == t.id) ? (lyrics?.lines ?? []) : []
        let idx = lyricIndex
        let cur = idx.flatMap { $0 < lines.count ? lines[$0].text : nil } ?? ""
        let nxt = idx.flatMap { $0 + 1 < lines.count ? lines[$0 + 1].text : nil } ?? (idx == nil ? (lines.first?.text ?? "") : "")
        let r = max(ratio, 0.1)
        let start = isPlaying ? Date().addingTimeInterval(-time / r) : nil
        let end = start.map { $0.addingTimeInterval(duration / r) }
        let fxLabel = currentFx.label
        if liveLyrics {
            LiveActivityManager.shared.update(.init(title: t.title, artist: t.artist, isPlaying: isPlaying, lyric: cur, nextLyric: nxt,
                                                     start: start, end: end, coverFile: thumbFile, fx: fxLabel,
                                                     elapsed: time / r, duration: duration / r))
        }
        guard track else { return }
        // Lyrics als Zeitplan fürs Widget: jede Zeile mit ihrer echten Uhrzeit
        var wl: [WidgetLyric] = []
        if isPlaying, let s = start {
            for l in lines {
                let at = s.addingTimeInterval(l.ms / 1000 / max(bakedRate, 0.1) / r)
                if at > Date().addingTimeInterval(-30) { wl.append(WidgetLyric(at: at, text: l.text)) }
            }
        }
        WidgetData.writeNowPlaying(WidgetNowPlaying(title: t.title, artist: t.artist, isPlaying: isPlaying, start: start, end: end,
                                                    lyrics: Array(wl.prefix(120)), coverFile: thumbFile, fx: fxLabel))
    }
}
