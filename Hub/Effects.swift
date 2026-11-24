import Foundation
import AVFoundation
import MediaToolbox
import Accelerate

/// Live-Bass für die Vorschau am Handy: Tiefen-Shelf (110 Hz) + Peak (55 Hz) wie die Hub-Kette, mit Lautstärke-Ausgleich
/// und weicher Begrenzung. Läuft als Audio-Tap im AVPlayer (auch offline). Der PC rechnet danach den exakten Hub-Sound.
final class BassProcessor: @unchecked Sendable {
    /// Bass-Änderung gegenüber der gespeicherten Datei in Prozentpunkten (−100 … +100)
    var delta: Double = 0 { didSet { dirty = true } }
    private var dirty = true
    private var sampleRate: Double = 44100
    private var channels = 2
    // Biquad-Zustand je Kanal: [x1, x2, y1, y2] für zwei Filter
    private var state: [[Float]] = []
    private var shelf: [Float] = [1, 0, 0, 0, 0]
    private var peak: [Float] = [1, 0, 0, 0, 0]
    private var makeup: Float = 1

    func prepare(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        state = Array(repeating: [0, 0, 0, 0, 0, 0, 0, 0], count: self.channels)
        dirty = true
    }

    private func update() {
        let s = delta / 100
        shelf = Self.lowShelf(f0: 110, gainDB: 24 * s, fs: sampleRate)
        peak = Self.peaking(f0: 55, gainDB: 10 * s, q: 1.0, fs: sampleRate)
        makeup = Float(pow(10, (-0.4 * 24 * s) / 20))   // ungefährer Lautheits-Ausgleich wie im Hub
        dirty = false
    }

    func process(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        if abs(delta) < 0.5 { return }
        if dirty { update() }
        for (ch, buf) in list.enumerated() where ch < state.count {
            guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            var st = state[ch]
            for i in 0..<frames {
                var x = p[i]
                // Filter 1: Shelf
                var y = shelf[0] * x + shelf[1] * st[0] + shelf[2] * st[1] - shelf[3] * st[2] - shelf[4] * st[3]
                st[1] = st[0]; st[0] = x; st[3] = st[2]; st[2] = y
                x = y
                // Filter 2: Peak
                y = peak[0] * x + peak[1] * st[4] + peak[2] * st[5] - peak[3] * st[6] - peak[4] * st[7]
                st[5] = st[4]; st[4] = x; st[7] = st[6]; st[6] = y
                // Ausgleich + weiche Begrenzung (kein Übersteuern)
                p[i] = tanhf(y * makeup)
            }
            state[ch] = st
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
