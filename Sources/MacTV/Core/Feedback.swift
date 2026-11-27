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
        get { preferences.navigationSounds }
        set { preferences.navigationSounds = newValue }
    }

    /// Volume for navigation sounds (0.0 to 1.0, defaults to 0.70).
    var volume: Float {
        get { preferences.navigationSoundVolume }
        set {
            let clamped = max(0, min(1, newValue))
            preferences.navigationSoundVolume = clamped
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
    /// One engine on the quiet (right) motor when available.
    private var controllerEngine: CHHapticEngine?
    private weak var hapticController: GCController?
    private var controllerEngineReady = false
    /// Latest cue waiting for an async engine start (first tap after connect).
    private var pendingControllerCue: Cue?
    /// Xbox / DS4 spinning motors vs DualSense voice-coil.
    private var controllerUsesRotatingMotors = true
    /// Retained so we can stop it before the next cue (Core Haptics layers players).
    private var controllerPlayer: CHHapticPatternPlayer?

    private let preferences: Preferences

    init(preferences: Preferences = .shared) {
        self.preferences = preferences
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

    /// Warm haptics when a pad connects. Idempotent for the same controller.
    func prepareControllerHaptics(_ controller: GCController) {
        guard controller.extendedGamepad != nil else { return }
        if controller === hapticController, controllerEngine != nil { return }
        attachControllerEngine(controller)
    }

    func clearControllerHaptics() {
        try? controllerPlayer?.stop(atTime: CHHapticTimeImmediate)
        controllerPlayer = nil
        controllerEngine?.stop()
        controllerEngine = nil
        hapticController = nil
        controllerEngineReady = false
        pendingControllerCue = nil
        controllerUsesRotatingMotors = true
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
        // Only the pad that is current, or the one we already warmed. Never scan
        // `controllers()` here: keyboard/pointer may be the last UI source while a
        // pad is still plugged in, and picking "first" would buzz the wrong device.
        guard let controller = GCController.current ?? hapticController else { return }
        if controller !== hapticController || controllerEngine == nil {
            attachControllerEngine(controller)
        }
        guard controllerEngineReady, controllerEngine != nil else {
            pendingControllerCue = cue
            startControllerEngine()
            return
        }
        playControllerPulse(cue)
    }

    private func attachControllerEngine(_ controller: GCController) {
        clearControllerHaptics()
        guard let haptics = controller.haptics else { return }
        controllerUsesRotatingMotors = !(controller.extendedGamepad is GCDualSenseGamepad)
        let supported = haptics.supportedLocalities
        // Right/weak motor when available (Microsoft: gentler). Else handles / default.
        let locality: GCHapticsLocality =
            supported.contains(.rightHandle) ? .rightHandle
            : supported.contains(.handles) ? .handles
            : .default
        guard let engine = haptics.createEngine(withLocality: locality) else { return }
        // Let an idle pad's engine stop to save its battery; the next tap restarts it (pending cue).
        engine.isAutoShutdownEnabled = true
        // Mark stale only; the next tap (or pending cue) restarts. Auto-restart here
        // would spin the engine while the pad is idle.
        engine.stoppedHandler = { [weak self] _ in
            Task { @MainActor in self?.controllerEngineReady = false }
        }
        engine.resetHandler = { [weak self] in
            Task { @MainActor in self?.controllerEngineReady = false }
        }
        controllerEngine = engine
        hapticController = controller
        controllerEngineReady = false
        startControllerEngine()
    }

    private func startControllerEngine() {
        guard let engine = controllerEngine else { return }
        engine.start { [weak self] error in
            Task { @MainActor in
                guard let self, error == nil else { return }
                self.controllerEngineReady = true
                if let cue = self.pendingControllerCue {
                    self.pendingControllerCue = nil
                    self.playControllerPulse(cue)
                }
            }
        }
    }

    private func playControllerPulse(_ cue: Cue) {
        guard let engine = controllerEngine else { return }
        let pulse = Self.controllerPulse(for: cue, rotatingMotors: controllerUsesRotatingMotors)
        try? controllerPlayer?.stop(atTime: CHHapticTimeImmediate)
        controllerPlayer = nil
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: pulse.intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness),
            ],
            relativeTime: 0,
            duration: pulse.duration
        )
        let envelope = Self.intensityEnvelope(for: cue, duration: pulse.duration)
        do {
            let player = try engine.makePlayer(
                with: CHHapticPattern(events: [event], parameterCurves: [envelope])
            )
            try player.start(atTime: CHHapticTimeImmediate)
            controllerPlayer = player
        } catch {
            controllerEngineReady = false
            pendingControllerCue = cue
            startControllerEngine()
        }
    }

    /// Move = needle tick, select = firmer press, back = single dull thump.
    /// ERM needs ~220ms+; DualSense stays short.
    static func controllerPulse(
        for cue: Cue,
        rotatingMotors: Bool
    ) -> (intensity: Float, sharpness: Float, duration: TimeInterval) {
        let duration: TimeInterval
        if rotatingMotors {
            switch cue {
            case .move: duration = 0.22
            case .select: duration = 0.28
            case .back: duration = 0.30
            }
        } else {
            switch cue {
            case .move: duration = 0.07
            case .select: duration = 0.10
            case .back: duration = 0.12
            }
        }
        switch cue {
        case .move: return (0.22, 0.88, duration)
        case .select: return (0.42, 0.52, duration)
        case .back: return (0.30, 0.22, duration)
        }
    }

    /// Shared ERM-friendly shapes; DualSense just runs them shorter via `controllerPulse`.
    /// Move `/\`, select `/‾\_`, back `/--\_` (no double click).
    static func intensityEnvelope(for cue: Cue, duration: TimeInterval) -> CHHapticParameterCurve {
        let d = duration
        let points: [CHHapticParameterCurve.ControlPoint]
        switch cue {
        case .move:
            points = [
                .init(relativeTime: 0, value: 0.40),
                .init(relativeTime: d * 0.12, value: 1.0),
                .init(relativeTime: d * 0.40, value: 0.70),
                .init(relativeTime: d * 0.70, value: 0.20),
                .init(relativeTime: d, value: 0),
            ]
        case .select:
            points = [
                .init(relativeTime: 0, value: 0.50),
                .init(relativeTime: d * 0.12, value: 1.0),
                .init(relativeTime: d * 0.55, value: 0.90),
                .init(relativeTime: d * 0.82, value: 0.30),
                .init(relativeTime: d, value: 0),
            ]
        case .back:
            points = [
                .init(relativeTime: 0, value: 0.35),
                .init(relativeTime: d * 0.20, value: 0.85),
                .init(relativeTime: d * 0.65, value: 0.70),
                .init(relativeTime: d * 0.88, value: 0.25),
                .init(relativeTime: d, value: 0),
            ]
        }
        return CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: points,
            relativeTime: 0
        )
    }
}
