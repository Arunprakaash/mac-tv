import AVFoundation
import AppKit
import Combine
import CoreHaptics
import GameController

/// Apple TV's interface feedback: a soft tick as focus moves, a click on select and a lower note
/// going back, with a matching tap on the trackpad or a game controller. The sounds are made here
/// rather than loaded from files, and only play on Mac TV's own screens, never over a show.
@MainActor
final class Feedback: ObservableObject {
    enum Cue: CaseIterable {
        case move, select, back
    }

    /// Where a command came from, so the haptic goes to the thing in the user's hand.
    /// The phone remote vibrates by itself.
    enum Source {
        case keyboard, trackpad, pointer, remote, controller
    }

    static let shared = Feedback()

    /// Sounds and haptics, on unless turned off in Settings.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "uiFeedback") as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "uiFeedback")
        }
    }

    /// Volume for navigation sounds (0.0 to 1.0, defaults to 0.70).
    var volume: Float {
        get { (UserDefaults.standard.object(forKey: "uiFeedbackVolume") as? Float) ?? 0.7 }
        set {
            objectWillChange.send()
            let clamped = max(0, min(1, newValue))
            UserDefaults.standard.set(clamped, forKey: "uiFeedbackVolume")
            engine.mainMixerNode.outputVolume = clamped
        }
    }

    var isMuted: Bool {
        !enabled
    }

    func toggleMute() {
        enabled.toggle()
        if enabled { play(.select, from: .keyboard) }
    }

    func stepVolume(by delta: Float) {
        let current = Int((volume * 100).rounded())
        let step = Int((delta * 100).rounded())
        let newPercent = max(0, min(100, current + step))
        volume = Float(newPercent) / 100.0
        if !enabled && delta > 0 { enabled = true }
        play(.move, from: .keyboard)
    }

    func setVolumePercent(_ percent: Int) {
        let clamped = max(0, min(100, percent))
        let current = Int((volume * 100).rounded())
        guard clamped != current || !enabled else { return }
        volume = Float(clamped) / 100.0
        if !enabled && clamped > 0 { enabled = true }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastAuditionTime >= 0.08 {
            lastAuditionTime = now
            play(.move, from: .keyboard)
        }
    }

    private var lastAuditionTime: TimeInterval = 0

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var buffers: [Cue: AVAudioPCMBuffer] = [:]
    private var idleTask: Task<Void, Never>?
    private var controllerEngine: CHHapticEngine?
    private weak var hapticController: GCController?

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        for cue in Cue.allCases { buffers[cue] = Self.synthesize(cue, format: format) }
        engine.mainMixerNode.outputVolume = volume
        // A few voices, so quick repeats overlap instead of cutting each other off.
        for _ in 0..<3 {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
        }
    }

    func play(_ cue: Cue, from source: Source) {
        guard enabled else { return }
        if source != .pointer { sound(cue) }
        haptic(cue, from: source)
    }

    // MARK: Sound

    private func sound(_ cue: Cue) {
        guard let buffer = buffers[cue] else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
        // An open audio stream keeps the Mac from idling to sleep; close it once things go quiet.
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.engine.pause()
        }
    }

    /// Muted, physical clicks rather than tones: a brief filtered noise transient (the "tick") over a
    /// low, quickly damped body (the "thock"). Move is the tick alone; select and back add a body,
    /// back a little lower and softer. No pitch sweeps, nothing bright.
    static func synthesize(_ cue: Cue, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        // tick: noise decay and low-pass cutoff; body: frequency, decay and gain.
        let (duration, level): (Double, Float)
        let (tickDecay, cutoff): (Double, Double)
        let (bodyFrequency, bodyDecay, bodyGain): (Double, Double, Double)
        switch cue {
        case .move:
            (duration, level) = (0.025, 0.07)
            (tickDecay, cutoff) = (0.0012, 2_600)
            (bodyFrequency, bodyDecay, bodyGain) = (900, 0.002, 0.25)
        case .select:
            (duration, level) = (0.08, 0.11)
            (tickDecay, cutoff) = (0.0015, 2_200)
            (bodyFrequency, bodyDecay, bodyGain) = (190, 0.016, 0.9)
        case .back:
            (duration, level) = (0.08, 0.09)
            (tickDecay, cutoff) = (0.0015, 1_600)
            (bodyFrequency, bodyDecay, bodyGain) = (150, 0.018, 0.8)
        }
        let frames = AVAudioFrameCount(duration * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        // The same noise every time, so each cue always sounds the same.
        var seed: UInt32 = 0x9E37_79B9
        let smoothing = 1 - exp(-2 * .pi * cutoff / rate)
        var filtered = 0.0
        var peak: Float = 0
        for frame in 0..<Int(frames) {
            let t = Double(frame) / rate
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed >> 8) / Double(1 << 24) * 2 - 1
            filtered += smoothing * (noise - filtered)
            let attack = min(1, t / 0.0004)
            let tick = filtered * exp(-t / tickDecay)
            let body = bodyGain * sin(2 * .pi * bodyFrequency * t) * exp(-t / bodyDecay)
            let value = Float(attack * (tick * 1.6 + body))
            samples[frame] = value
            peak = max(peak, abs(value))
        }
        // Same loudness whatever the mix: scale so each cue peaks at its level.
        if peak > 0 { for frame in 0..<Int(frames) { samples[frame] *= level / peak } }
        return buffer
    }

    // MARK: Haptics

    private func haptic(_ cue: Cue, from source: Source) {
        switch source {
        case .trackpad, .pointer:
            // Felt while a finger is on a Force Touch trackpad; the trackpad's own click covers select.
            guard cue == .move else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        case .controller:
            controllerTap(cue)
        case .keyboard, .remote:
            break
        }
    }

    private func controllerTap(_ cue: Cue) {
        guard let controller = GCController.current ?? GCController.controllers().first else { return }
        if controller !== hapticController {
            controllerEngine?.stop()
            controllerEngine = controller.haptics?.createEngine(withLocality: .default)
            controllerEngine?.isAutoShutdownEnabled = true
            hapticController = controller
        }
        guard let engine = controllerEngine else { return }
        let (intensity, sharpness): (Float, Float) = switch cue {
        case .move: (0.35, 0.7)
        case .select: (0.75, 0.5)
        case .back: (0.55, 0.25)
        }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: 0)
        do {
            try engine.start()
            try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: [])).start(atTime: CHHapticTimeImmediate)
        } catch {}
    }
}
