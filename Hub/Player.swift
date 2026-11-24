import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// Wiedergabe: offline aus dem Speicher (oder vom PC gestreamt), im Hintergrund, mit Sperrbildschirm-Steuerung.
@MainActor
final class Player: ObservableObject {
    enum Repeat: Int { case off, all, one }
    enum Sleep: Equatable { case off, minutes(Int), endOfSong }

    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var shuffle: Bool = UserDefaults.standard.bool(forKey: "shuffle") {
        didSet { UserDefaults.standard.set(shuffle, forKey: "shuffle"); rebuildOrder(keep: current) }
    }
    @Published var repeatMode: Repeat = Repeat(rawValue: UserDefaults.standard.integer(forKey: "repeat")) ?? .all {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeat") }
    }
    @Published private(set) var sleep: Sleep = .off
    @Published private(set) var sleepEnds: Date?
    @Published var message: String?

    weak var library: Library?
    private let player = AVPlayer()
    private var order: [String] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var artwork: MPMediaItemArtwork?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
        setupRemote()
    }

    private var tracks: [Track] { library?.tracks ?? [] }

    // MARK: Steuerung

    func play(_ t: Track) {
        guard let lib = library else { return }
        let url: URL
        if let local = lib.localURL(t) { url = local }
        else if lib.pcOnline, let remote = lib.streamURL(t) { url = remote }
        else { message = "„\(t.title)“ ist noch nicht offline gespeichert"; return }
        try? AVAudioSession.sharedInstance().setActive(true)
        current = t
        if !order.contains(t.id) { rebuildOrder(keep: t) }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        isPlaying = true
        time = 0
        duration = (t.duration ?? 0) / 1000 / max(t.rate, 0.1)
        UserDefaults.standard.set(t.id, forKey: "lastTrack")
        loadArtwork(t)
        updateNowPlaying()
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
            player.play(); isPlaying = true
        }
        updateNowPlaying()
    }

    func next() { step(1) }
    func previous() {
        if time > 3 { seek(to: 0) } else { step(-1) }
    }
    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        time = seconds
        updateNowPlaying()
    }

    func setSleep(_ s: Sleep) {
        sleep = s
        if case .minutes(let m) = s { sleepEnds = Date().addingTimeInterval(Double(m) * 60) } else { sleepEnds = nil }
    }

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
        // nur Songs, die abspielbar sind (offline oder PC da)
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
        if repeatMode == .one { seek(to: 0); player.play(); return }
        step(1)
    }

    private func tick(_ seconds: Double) {
        if seconds.isFinite { time = seconds }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        if let end = sleepEnds, Date() >= end { fadeOutAndStop() }
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
        }
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
        Task { @MainActor in
            guard let img = await CoverCache.shared.image(for: t.cover), current?.id == t.id else { return }
            artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard let t = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
