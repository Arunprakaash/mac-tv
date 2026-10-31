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
/// focus (repeating while held), A selects, B goes back, Menu goes home, X plays or pauses, and
/// the shoulder buttons skip. macOS delivers controller input only to the app in front, so while
/// a Steam game is playing the controller belongs to the game.
@MainActor
final class ControllerInput {
    private weak var tv: TVController?
    private var held: RemoteCommand.Direction?
    private var repeatTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(tv: TVController) {
        self.tv = tv
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            let controller = note.object as? GCController
            MainActor.assumeIsolated { self?.connect(controller) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            let controller = note.object as? GCController
            MainActor.assumeIsolated { self?.disconnect(controller) }
        })
        GCController.controllers().forEach(connect)
    }

    private func connect(_ controller: GCController?) {
        guard let controller, let pad = controller.extendedGamepad else { return }
        // A PlayStation controller's light bar glows Mac TV's phosphor green.
        controller.light?.color = GCColor(red: 0.25, green: 0.94, blue: 0.56)
        press(pad.buttonA, .select)
        press(pad.buttonB, .back)
        press(pad.buttonX, .playPause)
        press(pad.buttonMenu, .home)
        press(pad.leftShoulder, .seek(forward: false))
        press(pad.rightShoulder, .seek(forward: true))
        pad.dpad.valueChangedHandler = { [weak self] _, x, y in MainActor.assumeIsolated { self?.steer(x: x, y: y) } }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in MainActor.assumeIsolated { self?.steer(x: x, y: y) } }
        tv?.controllerChanged(Self.info(for: controller), connected: true)
    }

    private func disconnect(_ controller: GCController?) {
        guard let controller else { return }
        stopRepeat()
        let next = GCController.controllers().first { $0 !== controller && $0.extendedGamepad != nil }
        tv?.controllerChanged(Self.info(for: controller), connected: false, remaining: next.map(Self.info(for:)))
    }

    private func press(_ button: GCControllerButtonInput, _ command: RemoteCommand) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { self?.send(command) }
        }
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
            info.menuSymbol = pad.buttonMenu.sfSymbolsName ?? info.menuSymbol
        }
        return info
    }
}

extension TVController {
    func controllerChanged(_ info: ControllerInfo, connected: Bool, remaining: ControllerInfo? = nil) {
        controller = connected ? info : remaining
        showControllerNotice(ControllerNotice(info: info, connected: connected))
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
            hint(info.menuSymbol, "Home")
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
