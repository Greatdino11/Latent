import AVFoundation
import UIKit

/// Haptics and the optional film-advance sound. (iOS plays its own shutter sound for every capture.)
@MainActor
enum Feedback {
    static var hapticsOn: Bool { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }
    static var advanceSoundOn: Bool { UserDefaults.standard.bool(forKey: "advanceSound") }

    static func shutter() {
        if hapticsOn { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
        if advanceSoundOn { FilmAdvanceSound.shared.play() }
    }

    /// A short ratchet of ticks, like winding to the next frame.
    static func advance() {
        guard hapticsOn else { return }
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(i) * 0.06) { gen.impactOccurred(intensity: 0.6) }
        }
    }

    static func selection() {
        if hapticsOn { UISelectionFeedbackGenerator().selectionChanged() }
    }

    static func success() {
        if hapticsOn { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }
}

/// A synthesised mechanical wind-on: a lever clack followed by a ratchet. Generated once, no audio files.
final class FilmAdvanceSound {
    static let shared = FilmAdvanceSound()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?

    private init() {
        let rate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let length = AVAudioFrameCount(rate * 0.42)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else { return }
        buf.frameLength = length
        let out = buf.floatChannelData![0]
        var seed: UInt32 = 0x1234567
        func noise() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) }
        func click(at t: Double, gain: Float, decay: Double, tone: Double) {
            let start = Int(t * rate)
            var lp: Float = 0
            for i in 0..<Int(rate * decay * 6) where start + i < Int(length) {
                let env = Float(exp(-Double(i) / (rate * decay)))
                lp += (noise() - lp) * 0.35                      // soften the noise
                let ring = Float(sin(2 * .pi * tone * Double(i) / rate))
                out[start + i] += (lp * 0.8 + ring * 0.25) * env * gain
            }
        }
        for i in 0..<Int(length) { out[i] = 0 }
        click(at: 0.10, gain: 0.55, decay: 0.006, tone: 1800)     // lever
        for k in 0..<7 { click(at: 0.16 + Double(k) * 0.032, gain: 0.22, decay: 0.003, tone: 3200) }   // ratchet
        click(at: 0.39, gain: 0.35, decay: 0.005, tone: 1400)     // lever returns
        buffer = buf

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play() {
        guard let buffer else { return }
        // Ambient: respects the silent switch and mixes with other audio.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buffer, at: nil, options: [.interrupts])
        player.play()
    }
}
