import Foundation
import AVFoundation
import MediaToolbox
import Accelerate

/// Ein Biquad-Filter (Direktform I) mit eigenem Zustand
struct Biquad {
    var c: [Float] = [1, 0, 0, 0, 0]          // b0, b1, b2, a1, a2 (a0 = 1)
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    mutating func run(_ x: Float) -> Float {
        let y = c[0] * x + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// Live-Bass am Handy – genau die Kette vom PC (src/songchain.js): Tiefen-Shelf 110 Hz + Peak 55 Hz, Vorverstärkung,
/// Sättigung (tanh, übersteuert absichtlich wie „bass boosted“), Kompressor. Danach wird die Lautheit (gemessen wie LUFS,
/// K-gewichtet) wieder auf die des Songs ohne Bass gebracht – Bass macht also NICHT leiser, sondern klingt wie am PC.
/// Läuft als Audio-Tap im AVPlayer (auch offline). Der PC rechnet danach die exakte Fassung.
final class BassProcessor: @unchecked Sendable {
    /// Bass-Änderung gegenüber der gespeicherten Datei in Prozentpunkten (−100 … +100)
    var delta: Double = 0 { didSet { dirty = true } }
    private var dirty = true
    private var sampleRate: Double = 44100
    private var channels = 2

    private struct Chan { var shelf = Biquad(), peak = Biquad(), kInHS = Biquad(), kInHP = Biquad(), kOutHS = Biquad(), kOutHP = Biquad() }
    private var ch: [Chan] = []
    // Parameter wie am PC
    private var pre: Float = 1, post: Float = 1, k: Float = 1, tanhK: Float = 1, saturate = false
    // Kompressor (Schwelle −4 dB, Knie 6 dB, Verhältnis 12, Attack 3 ms, Release 120 ms)
    private var compGainDB: Float = 0, atk: Float = 0, rel: Float = 0
    // Lautheits-Ausgleich: K-gewichtete mittlere Leistung vorher/nachher
    private var msIn: Double = 0, msOut: Double = 0, seen: Double = 0, makeup: Float = 1
    // feste Puffer (im Audio-Thread nichts neu anlegen)
    private var tmp = [Float](repeating: 0, count: 8)
    private var ptrs = [UnsafeMutablePointer<Float>?](repeating: nil, count: 8)

    func prepare(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        ch = Array(repeating: Chan(), count: self.channels)
        dirty = true
    }

    private func update() {
        let s = max(-1, min(1, delta / 100))
        let shelf = Self.lowShelf(f0: 110, gainDB: 24 * s, fs: sampleRate)
        let peak = Self.peaking(f0: 55, gainDB: 10 * s, q: 0.9, fs: sampleRate)
        let kHS = Self.highShelf(f0: 1681.97, gainDB: 4, fs: sampleRate)
        let kHP = Self.highPass(f0: 38.13, q: 0.5, fs: sampleRate)
        for i in ch.indices {
            ch[i].shelf.c = shelf; ch[i].peak.c = peak
            ch[i].kInHS.c = kHS; ch[i].kInHP.c = kHP; ch[i].kOutHS.c = kHS; ch[i].kOutHP.c = kHP
        }
        // Sättigung nur beim Anheben (weniger Bass als in der Datei = nur Filter)
        let up = max(0, s)
        saturate = up > 0
        pre = Float(1 + 3 * up)
        k = Float((1 + 14 * up) * 10).rounded() / 10
        tanhK = tanhf(k)
        post = saturate ? Float(1 / (1 + 1.6 * up)) : 1
        atk = Float(exp(-1 / (0.003 * sampleRate)))
        rel = Float(exp(-1 / (0.12 * sampleRate)))
        msIn = 0; msOut = 0; seen = 0
        makeup = Float(pow(10, -0.4 * 24 * up / 20))    // Startwert bis gemessen ist (kein lauter Knall beim Umschalten)
        dirty = false
    }

    @inline(__always) private func compress(_ peak: Float) -> Float {
        // Pegel in dB → Soll-Absenkung mit weichem Knie
        let x = 20 * log10f(max(peak, 1e-6)), T: Float = -4, W: Float = 6, R: Float = 12
        var y = x
        if 2 * (x - T) > W { y = T + (x - T) / R }
        else if 2 * abs(x - T) <= W { let d = x - T + W / 2; y = x + (1 / R - 1) * d * d / (2 * W) }
        let want = y - x                               // ≤ 0
        compGainDB = want < compGainDB ? atk * compGainDB + (1 - atk) * want : rel * compGainDB + (1 - rel) * want
        return powf(10, compGainDB / 20)
    }

    func process(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        if abs(delta) < 0.5 { return }
        if dirty { update() }
        let n = min(list.count, ch.count, 8)
        guard n > 0 else { return }
        for c in 0..<n {
            guard let p = list[c].mData?.assumingMemoryBound(to: Float.self) else { return }
            ptrs[c] = p
        }
        var sumIn: Double = 0, sumOut: Double = 0
        for i in 0..<frames {
            var peakAbs: Float = 0
            for c in 0..<n {
                let x = ptrs[c]![i]
                let kw = ch[c].kInHP.run(ch[c].kInHS.run(x)); sumIn += Double(kw * kw)
                var y = ch[c].peak.run(ch[c].shelf.run(x))
                if saturate { y = tanhf(k * max(-1, min(1, y * pre))) / tanhK * post }
                tmp[c] = y
                peakAbs = max(peakAbs, abs(y))
            }
            let g = saturate ? compress(peakAbs) : 1
            for c in 0..<n {
                let y = tmp[c] * g
                let kw = ch[c].kOutHP.run(ch[c].kOutHS.run(y)); sumOut += Double(kw * kw)
                ptrs[c]![i] = max(-1, min(1, y * makeup))   // wie WebAudio am Ausgang: hart bei ±1
            }
        }
        // Lautheit angleichen: die ersten 8 s laufender Mittelwert, danach gleitend (≈ 8 s) – wie ein fester Ausgleich pro Song
        let t = Double(frames) / sampleRate
        seen += t
        let w = seen < 8 ? t / seen : t / 8
        msIn += (sumIn / Double(frames * n) - msIn) * w
        msOut += (sumOut / Double(frames * n) - msOut) * w
        if msIn > 1e-7, msOut > 1e-9 {                 // Stille nicht mitzählen
            let target = Float(max(0.1, min(1.4, sqrt(msIn / msOut))))
            makeup += (target - makeup) * Float(seen <= t * 1.5 ? 1 : min(1, t / 0.5))   // erster Block: sofort richtig
        }
    }

    // RBJ-Audio-EQ-Kochbuch, normiert auf a0 = 1 → [b0, b1, b2, a1, a2]
    static func lowShelf(f0: Double, gainDB: Double, fs: Double) -> [Float] {
        let A = pow(10, gainDB / 40), w = 2 * Double.pi * f0 / fs, cw = cos(w), sw = sin(w)
        let alpha = sw / 2 * sqrt(2.0), b = 2 * sqrt(A) * alpha
        let b0 = A * ((A + 1) - (A - 1) * cw + b), b1 = 2 * A * ((A - 1) - (A + 1) * cw), b2 = A * ((A + 1) - (A - 1) * cw - b)
        let a0 = (A + 1) + (A - 1) * cw + b, a1 = -2 * ((A - 1) + (A + 1) * cw), a2 = (A + 1) + (A - 1) * cw - b
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0].map { Float($0) }
    }
    static func peaking(f0: Double, gainDB: Double, q: Double, fs: Double) -> [Float] {
        let A = pow(10, gainDB / 40), w = 2 * Double.pi * f0 / fs, cw = cos(w), alpha = sin(w) / (2 * q)
        let b0 = 1 + alpha * A, b1 = -2 * cw, b2 = 1 - alpha * A, a0 = 1 + alpha / A, a1 = -2 * cw, a2 = 1 - alpha / A
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0].map { Float($0) }
    }
    static func highShelf(f0: Double, gainDB: Double, fs: Double) -> [Float] {
        let A = pow(10, gainDB / 40), w = 2 * Double.pi * f0 / fs, cw = cos(w), sw = sin(w)
        let alpha = sw / 2 * sqrt(2.0), b = 2 * sqrt(A) * alpha
        let b0 = A * ((A + 1) + (A - 1) * cw + b), b1 = -2 * A * ((A - 1) + (A + 1) * cw), b2 = A * ((A + 1) + (A - 1) * cw - b)
        let a0 = (A + 1) - (A - 1) * cw + b, a1 = 2 * ((A - 1) - (A + 1) * cw), a2 = (A + 1) - (A - 1) * cw - b
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0].map { Float($0) }
    }
    static func highPass(f0: Double, q: Double, fs: Double) -> [Float] {
        let w = 2 * Double.pi * f0 / fs, cw = cos(w), alpha = sin(w) / (2 * q)
        let b0 = (1 + cw) / 2, b1 = -(1 + cw), b2 = (1 + cw) / 2, a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0].map { Float($0) }
    }
}

/// Spielt Stille, damit die App nach dem Pausieren ein paar Minuten wach bleibt
/// (nötig, um Sperrbildschirm-Anzeige/Dynamic Island nach 3 Minuten ohne Musik selbst zu entfernen).
final class KeepAlive {
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?

    func start() {
        guard engine == nil else { return }
        let e = AVAudioEngine(), n = AVAudioPlayerNode()
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100) else { return }
        buf.frameLength = 44100          // eine Sekunde Stille
        if let ch = buf.floatChannelData {
            for c in 0..<Int(fmt.channelCount) { ch[c].update(repeating: 0, count: 44100) }
        }
        e.attach(n)
        e.connect(n, to: e.mainMixerNode, format: fmt)
        e.mainMixerNode.outputVolume = 0
        do { try e.start() } catch { return }
        n.scheduleBuffer(buf, at: nil, options: .loops)
        n.play()
        engine = e
        node = n
    }

    func stop() {
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
    }
}

enum AudioTap {
    /// Hängt den Bass-Prozessor an ein AVPlayerItem (über einen Audio-Mix)
    static func attach(_ processor: BassProcessor, to item: AVPlayerItem) async {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(processor).toOpaque()),
            init: { _, clientInfo, tapStorageOut in tapStorageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<BassProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let p = Unmanaged<BassProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                p.prepare(sampleRate: format.pointee.mSampleRate, channels: Int(format.pointee.mChannelsPerFrame))
            },
            unprepare: nil,
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut) == noErr else { return }
                let p = Unmanaged<BassProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                p.process(UnsafeMutableAudioBufferListPointer(bufferListInOut), frames: Int(numberFramesOut.pointee))
            })
        // Der Ausgabe-Parameter heißt je nach SDK `MTAudioProcessingTap?` oder `Unmanaged<…>?` – beide sind ein Zeiger,
        // also über einen rohen Speicherplatz gehen und die (+1) Referenz selbst übernehmen.
        var slot: UnsafeMutableRawPointer? = nil
        let status: OSStatus = withUnsafeMutablePointer(to: &slot) { p in
            MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, rebind(p))
        }
        guard status == noErr, let raw = slot else { return }
        let tap = Unmanaged<MTAudioProcessingTap>.fromOpaque(raw).takeRetainedValue()
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        await MainActor.run { item.audioMix = mix }
    }

    private static func rebind<T>(_ p: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> UnsafeMutablePointer<T> {
        UnsafeMutableRawPointer(p).assumingMemoryBound(to: T.self)
    }
}
