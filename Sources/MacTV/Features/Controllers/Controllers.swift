import GameController
import SwiftUI

/// What the TV shows about a connected game controller.
struct ControllerInfo: Equatable {
    var name: String
    /// 0–1, when the controller reports it.
    var battery: Float?
    var charging = false
    /// Apple's symbols for this controller's own buttons: ✕ and ○ on PlayStation, A and B on Xbox.
    var selectSymbol = "a.circle"
    var backSymbol = "b.circle"
    var xSymbol = "x.circle"
    var ySymbol = "y.circle"
    var leftTriggerSymbol = "l2.button.angledbottom.horizontal.left"
    var menuSymbol = "line.3.horizontal.circle"

    var batterySymbol: String {
        if charging { return "battery.100percent.bolt" }
        guard let battery else { return "battery.100percent" }
        switch battery {
        case ..<0.15: return "battery.0percent"
        case ..<0.4: return "battery.25percent"
        case ..<0.65: return "battery.50percent"
        case ..<0.9: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// A controller connecting or disconnecting, shown for a moment at the top of the TV.
struct ControllerNotice: Equatable {
    let info: ControllerInfo
    let connected: Bool
}

/// Game controllers drive Mac TV the way they drive Apple TV: the D-pad or left stick moves
/// focus (repeating while held), A selects, B goes back, Menu/Start opens Settings on the home
/// screen (elsewhere it goes home — Xbox's Menu button), X plays or pauses, and the shoulder
/// buttons skip in playback or step horizontal menus (Add App tabs, settings).
/// Y opens the on-screen keyboard (while open: X deletes, Y spaces, L2 shifts); L2/R2 ramp volume while held; Options mutes.
/// The right stick tilts the focused home-screen tile like pointer hover.
/// A long B press goes Home. macOS delivers controller input only to the app in front, so while
/// a Steam game is playing the controller belongs to the game.
@MainActor
final class ControllerInput {
    private weak var tv: TVController?
    private var held: RemoteCommand.Direction?
    private var repeatTimer: Timer?
    private var volumeTimer: Timer?
    private var volumeUp = false
    private var volumeDown = false
    private var volumeHoldStarted: TimeInterval?
    private var observers: [NSObjectProtocol] = []
    private var backPressStarted: TimeInterval?
    private var backLongFired = false
    private static let backLongPress: TimeInterval = 0.55
    /// Base tick; step size grows the longer a trigger is held (see `volumeStep`).
    private static let volumeTick: TimeInterval = 0.035

    init(tv: TVController) {
        self.tv = tv
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            // Delivered on the main queue, which is where the controller is used.
            nonisolated(unsafe) let controller = note.object as? GCController
            MainActor.assumeIsolated { self?.connect(controller) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            // Delivered on the main queue, which is where the controller is used.
            nonisolated(unsafe) let controller = note.object as? GCController
            MainActor.assumeIsolated { self?.disconnect(controller) }
        })
        GCController.controllers().forEach(connect)
    }

    private func connect(_ controller: GCController?) {
        guard let controller, let pad = controller.extendedGamepad else { return }
        // A PlayStation controller's light bar glows Mac TV's phosphor green.
        controller.light?.color = GCColor(red: 0.25, green: 0.94, blue: 0.56)
        press(pad.buttonA, .select)
        pressBack(pad.buttonB)
        pressDelete(pad.buttonX)
        press(pad.buttonY, .keyboard)
        // Xbox Menu/Start (≡); DualSense Options mutes (View/Back stays separate when present).
        pressMenu(pad.buttonMenu)
        press(pad.leftShoulder, .seek(forward: false))
        press(pad.rightShoulder, .seek(forward: true))
        pressShift(pad.leftTrigger)
        volumeTrigger(pad.leftTrigger, up: false)
        volumeTrigger(pad.rightTrigger, up: true)
        if let options = pad.buttonOptions {
            press(options, .mute)
        }
        pad.dpad.valueChangedHandler = { [weak self] _, x, y in MainActor.assumeIsolated { self?.steer(x: x, y: y) } }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in MainActor.assumeIsolated { self?.steer(x: x, y: y) } }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in MainActor.assumeIsolated { self?.tiltFocusedTile(x: x, y: y) } }
        Feedback.shared.prepareControllerHaptics(controller)
        tv?.controllerChanged(Self.info(for: controller), connected: true)
    }

    private func disconnect(_ controller: GCController?) {
        guard let controller else { return }
        stopRepeat()
        stopVolumeRamp()
        tv?.tilt = .zero
        backPressStarted = nil
        backLongFired = false
        let next = GCController.controllers().first { $0 !== controller && $0.extendedGamepad != nil }
        if let next {
            Feedback.shared.prepareControllerHaptics(next)
        } else {
            Feedback.shared.clearControllerHaptics()
        }
        tv?.controllerChanged(Self.info(for: controller), connected: false, remaining: next.map(Self.info(for:)))
    }

    private func press(_ button: GCControllerButtonInput, _ command: RemoteCommand) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                // Arrange Remove needs Down/Up; everywhere else Select stays a single edge.
                if case .select = command {
                    if self?.tv?.organizer != nil {
                        self?.send(pressed ? .selectDown : .selectUp)
                    } else if pressed {
                        self?.send(.select)
                    }
                } else if pressed {
                    self?.send(command)
                }
            }
        }
    }

    /// Menu/Start: Settings on the idle home screen; Home everywhere else (so the dashboard isn't a dead button).
    private func pressMenu(_ button: GCControllerButtonInput) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { self?.tv?.handleControllerMenu() }
        }
    }

    /// B: short press is Back; hold ~0.55s jumps Home (unless the on-screen keyboard is open).
    private func pressBack(_ button: GCControllerButtonInput) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                guard let self else { return }
                if pressed {
                    self.backPressStarted = ProcessInfo.processInfo.systemUptime
                    self.backLongFired = false
                    let started = self.backPressStarted
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.backLongPress) {
                        MainActor.assumeIsolated {
                            guard self.backPressStarted == started, !self.backLongFired else { return }
                            if self.tv?.onScreenKeyboard.isOpen == true { return }
                            self.backLongFired = true
                            self.send(.home)
                        }
                    }
                } else {
                    let held = self.backPressStarted.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
                    self.backPressStarted = nil
                    if self.backLongFired { self.backLongFired = false; return }
                    if held < Self.backLongPress { self.send(.back) }
                }
            }
        }
    }

    /// L2 as Shift only while the on-screen keyboard is open.
    private func pressShift(_ button: GCControllerButtonInput) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                guard self?.tv?.onScreenKeyboard.isOpen == true else { return }
                self?.send(.keyboardShift(pressed))
            }
        }
    }

    /// X: play/pause normally; while the keyboard is open, hold lights Delete and press deletes.
    private func pressDelete(_ button: GCControllerButtonInput) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.tv?.onScreenKeyboard.isOpen == true {
                    self.tv?.setKeyboardDeleteHeld(pressed)
                    if pressed { self.send(.playPause) }
                    return
                }
                if pressed { self.send(.playPause) }
            }
        }
    }

    /// Analog hold: keep stepping volume while the trigger is pulled (skipped while the keyboard uses L2).
    private func volumeTrigger(_ button: GCControllerButtonInput, up: Bool) {
        button.valueChangedHandler = { [weak self] _, value, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // L2 is Shift while the keyboard is open; tickVolume also bails if a ramp was mid-hold.
                if self.tv?.onScreenKeyboard.isOpen == true { return }
                self.setVolumeHeld(up: up, held: value >= 0.08)
            }
        }
    }

    private func setVolumeHeld(up: Bool, held: Bool) {
        let was = volumeUp || volumeDown
        if up { volumeUp = held } else { volumeDown = held }
        let now = volumeUp || volumeDown
        if now, !was {
            volumeHoldStarted = ProcessInfo.processInfo.systemUptime
            tickVolume()
            volumeTimer?.invalidate()
            volumeTimer = Timer.scheduledTimer(withTimeInterval: Self.volumeTick, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickVolume() }
            }
        } else if !now {
            stopVolumeRamp()
        }
    }

    private func tickVolume() {
        if tv?.onScreenKeyboard.isOpen == true {
            stopVolumeRamp()
            return
        }
        let delta = (volumeUp ? 1 : 0) - (volumeDown ? 1 : 0)
        guard delta != 0 else { stopVolumeRamp(); return }
        let held = volumeHoldStarted.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        send(.volume(delta * Self.volumeStep(heldFor: held)))
    }

    /// 1 at press → 5 after ~1.2s (full 0–100 in ~0.7s at max).
    static func volumeStep(heldFor: TimeInterval) -> Int {
        min(5, 1 + Int(heldFor / 0.3))
    }

    private func stopVolumeRamp() {
        volumeTimer?.invalidate()
        volumeTimer = nil
        volumeUp = false
        volumeDown = false
        volumeHoldStarted = nil
    }

    /// Right stick: same -0.5…0.5 tilt as mouse hover over a home tile.
    private func tiltFocusedTile(x: Float, y: Float) {
        guard let tv, tv.mode == .launcher, tv.movies == nil, tv.sheets.top == nil,
              case .app = tv.focus else { return }
        if max(abs(x), abs(y)) < 0.08 {
            tv.tilt = .zero
            return
        }
        // Stick Y is up-positive; mouse tilt Y is down-positive.
        tv.tilt = CGSize(width: CGFloat(x) * 0.5, height: CGFloat(-y) * 0.5)
    }

    /// Stick and D-pad positions become one direction at a time; holding it repeats, like a remote.
    func steer(x: Float, y: Float) {
        let direction = Self.direction(x: x, y: y)
        guard direction != held else { return }
        held = direction
        stopRepeat()
        guard let direction else { return }
        send(.move(direction))
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.13, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { if let held = self?.held { self?.send(.move(held)) } }
                }
            }
        }
    }

    /// The direction a stick or D-pad points, once it's pushed past halfway.
    static func direction(x: Float, y: Float) -> RemoteCommand.Direction? {
        guard max(abs(x), abs(y)) >= 0.5 else { return nil }
        if abs(x) > abs(y) { return x > 0 ? .right : .left }
        return y > 0 ? .up : .down
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func send(_ command: RemoteCommand) {
        tv?.handle(command, from: .controller)
    }

    static func info(for controller: GCController) -> ControllerInfo {
        var info = ControllerInfo(name: controller.vendorName ?? "Game controller")
        if let battery = controller.battery {
            info.battery = battery.batteryLevel
            info.charging = battery.batteryState == .charging || battery.batteryState == .full
        }
        if let pad = controller.extendedGamepad {
            info.selectSymbol = pad.buttonA.sfSymbolsName ?? info.selectSymbol
            info.backSymbol = pad.buttonB.sfSymbolsName ?? info.backSymbol
            info.xSymbol = pad.buttonX.sfSymbolsName ?? info.xSymbol
            info.ySymbol = pad.buttonY.sfSymbolsName ?? info.ySymbol
            info.leftTriggerSymbol = pad.leftTrigger.sfSymbolsName ?? info.leftTriggerSymbol
            info.menuSymbol = pad.buttonMenu.sfSymbolsName ?? info.menuSymbol
        }
        return info
    }
}

extension TVController {
    func controllerChanged(_ info: ControllerInfo, connected: Bool, remaining: ControllerInfo? = nil) {
        // Haptics warm/clear happens in ControllerInput.connect/disconnect (once).
        controller = connected ? info : remaining
        if controller == nil { closeOnScreenKeyboard() }
        showControllerNotice(ControllerNotice(info: info, connected: connected))
    }

    /// Xbox Menu / DualSense Options: toggle Settings on the home dock; otherwise behave like Home.
    func handleControllerMenu() {
        if onScreenKeyboard.isOpen || webTyping {
            dismissWebTyping()
            feedback.play(.back, from: .controller)
            return
        }
        if settings != nil {
            settings = nil
            feedback.play(.back, from: .controller)
            return
        }
        if mode == .launcher, sheets.top == nil, movies == nil {
            openSettings()
            feedback.play(.select, from: .controller)
            return
        }
        handle(.home, from: .controller)
    }
}

// MARK: Views

/// Apple TV's controller banner: a glass capsule with the controller, its name and its battery.
struct ControllerBanner: View {
    let notice: ControllerNotice

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 26, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.info.name).font(.tv(.caption2)).lineLimit(1)
                Text(notice.connected ? "Connected" : "Disconnected").font(.tv(.caption2)).foregroundStyle(.white.opacity(0.65))
            }
            if notice.connected, notice.info.battery != nil || notice.info.charging {
                Image(systemName: notice.info.batterySymbol).font(.system(size: 22)).foregroundStyle(.white.opacity(0.8))
                    .padding(.leading, 6)
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 22).padding(.trailing, 26)
        .frame(height: 76)
        .tvGlass(in: Capsule())
    }
}

/// The controller's own buttons and what they do, shown beside the clock while one is connected.
struct ControllerHints: View {
    let info: ControllerInfo

    var body: some View {
        HStack(spacing: 18) {
            hint(info.selectSymbol, "Open")
            hint(info.backSymbol, "Back")
            hint(info.ySymbol, "Keyboard")
            hint(info.menuSymbol, "Menu")
        }
        .font(.tv(.caption2))
        .padding(.horizontal, 20)
        .frame(height: 50)
        .tvGlass(in: Capsule())
    }

    private func hint(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 22, weight: .medium)).symbolRenderingMode(.hierarchical)
            Text(label)
        }
    }
}
