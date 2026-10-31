import SwiftUI

/// Apple TV's Control Center: a small cluster of glass tiles under the status row at the top right,
/// for the things people change most. Opened from the status row's Control Center button.
struct ControlCenterPanel: Equatable {
    enum Item: CaseIterable {
        case sleepMac, phone, sounds, sleepTimer, skipIntros, controller, screenOff, lid, settings
    }

    var item: Item = .phone
    /// Sleep Mac asks for a second press.
    var confirmingSleep = false

    /// Where each direction goes from each item.
    static func neighbour(of item: Item, _ direction: RemoteCommand.Direction) -> Item? {
        switch (item, direction) {
        case (.sleepMac, .right): .phone
        case (.sleepMac, .down): .sleepTimer
        case (.phone, .left), (.sounds, .left): .sleepMac
        case (.phone, .down): .sounds
        case (.sounds, .up): .phone
        case (.sounds, .down): .skipIntros
        case (.sleepTimer, .up): .sleepMac
        case (.sleepTimer, .right): .skipIntros
        case (.sleepTimer, .down): .controller
        case (.skipIntros, .up): .sounds
        case (.skipIntros, .left): .sleepTimer
        case (.skipIntros, .down): .lid
        case (.controller, .up), (.screenOff, .up): .sleepTimer
        case (.controller, .right): .screenOff
        case (.screenOff, .left): .controller
        case (.screenOff, .right): .lid
        case (.lid, .up), (.settings, .up): .skipIntros
        case (.lid, .left): .screenOff
        case (.lid, .right): .settings
        case (.settings, .left): .lid
        default: nil
        }
    }
}

extension TVController {
    func openControlCenter() {
        controlCenter = ControlCenterPanel()
        Analytics.send(.controlCenterOpened)
    }

    func handleControlCenter(_ command: RemoteCommand) {
        guard var panel = controlCenter else { return }
        if case .select = command {} else { panel.confirmingSleep = false }
        switch command {
        case .back:
            controlCenter = nil
            return
        case .move(let direction):
            if let next = ControlCenterPanel.neighbour(of: panel.item, direction) {
                panel.item = next
            } else if direction == .up, panel.item == .sleepMac || panel.item == .phone {
                // Up from the top row goes back to the status row's Control Center button.
                controlCenter = nil
                return
            } else if direction == .down, panel.item == .controller || panel.item == .screenOff
                        || panel.item == .lid || panel.item == .settings {
                controlCenter = nil
                return
            }
        case .select:
            controlCenter = panel
            activateControl(panel.item)
            return
        default:
            break
        }
        controlCenter = panel
    }

    func activateControl(_ item: ControlCenterPanel.Item) {
        controlCenter?.item = item
        Analytics.send(.controlUsed, ["control": String(describing: item)])
        switch item {
        case .sleepMac:
            if controlCenter?.confirmingSleep == true {
                controlCenter = nil
                goHome()
                SystemControl.sleepNow()
            } else {
                controlCenter?.confirmingSleep = true
            }
        case .phone:
            controlCenter = nil
            pairing = true
        case .sounds: Feedback.shared.enabled.toggle()
        case .sleepTimer: stepSleepTimer(by: 1, wrap: true)
        case .skipIntros: autoSkip.toggle()
        case .controller:
            showToast(controller.map { "\($0.name)\($0.battery.map { ", battery \(Int($0 * 100))%" } ?? "")" }
                      ?? "Pair a controller in System Settings › Bluetooth")
        case .screenOff: SystemControl.displayOff()
        case .lid: lidOverride.toggle()
        case .settings:
            controlCenter = nil
            openSettings()
        }
        objectWillChange.send()
    }
}

// MARK: Views

struct ControlCenterView: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas
    private static let column: CGFloat = 256
    private static let row: CGFloat = 96
    private static let gap: CGFloat = 16

    var body: some View {
        let panel = tv.controlCenter ?? ControlCenterPanel()
        VStack(alignment: .trailing, spacing: 26) {
            GlassGroup(spacing: 0) {
                VStack(spacing: Self.gap) {
                    HStack(alignment: .top, spacing: Self.gap) {
                        sleepTile(panel)
                        VStack(spacing: Self.gap) {
                            tile(.phone, panel, symbol: "iphone", title: "Phone",
                                 detail: tv.phonePaired ? "Connected" : "Set up", on: tv.phonePaired)
                            tile(.sounds, panel, symbol: Feedback.shared.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                 title: "Sounds", detail: Feedback.shared.enabled ? "On" : "Off", on: Feedback.shared.enabled)
                        }
                    }
                    HStack(spacing: Self.gap) {
                        let minutes = tv.sleepMinutesLeft
                        tile(.sleepTimer, panel, symbol: minutes > 0 ? "moon.zzz.fill" : "timer", title: "Sleep Timer",
                             detail: minutes > 0 ? "\(minutes) min" : "Off", on: minutes > 0)
                        tile(.skipIntros, panel, symbol: tv.autoSkip ? "forward.end.fill" : "forward.end", title: "Skip Intros",
                             detail: tv.autoSkip ? "On" : "Off", on: tv.autoSkip)
                    }
                    HStack(spacing: Self.gap) {
                        round(.controller, panel, symbol: "gamecontroller.fill", on: tv.controller != nil)
                        round(.screenOff, panel, symbol: "tv.slash", on: true)
                        round(.lid, panel, symbol: tv.lidOverride ? "laptopcomputer" : "laptopcomputer.slash", on: tv.lidOverride)
                        round(.settings, panel, symbol: "gearshape.fill", on: true)
                    }
                }
            }
            Text(caption(panel))
                .font(.tv(.caption2))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: Self.column * 2 + Self.gap, alignment: .center)
                .contentTransition(.opacity)
        }
        .foregroundStyle(.white)
        // Just under the home screen's status row, which stays in place above it.
        .padding(.top, 136)
        .padding(.trailing, 96)
        .frame(width: canvas.width, height: canvas.height, alignment: .topTrailing)
        .animation(Motion.focus, value: panel)
    }

    /// What the focused round button does, shown under the cluster since those buttons have no label.
    private func caption(_ panel: ControlCenterPanel) -> String {
        switch panel.item {
        case .controller: tv.controller?.name ?? "No controller connected"
        case .screenOff: "Turn Screen Off"
        case .lid: tv.lidOverride ? "Stays awake with the lid closed" : "Sleeps when the lid closes"
        case .settings: "All Settings"
        case .sleepMac: panel.confirmingSleep ? "Press again to sleep the Mac" : "Sleep Mac"
        default: " "
        }
    }

    private func sleepTile(_ panel: ControlCenterPanel) -> some View {
        let focused = panel.item == .sleepMac
        let warning = panel.confirmingSleep
        return VStack(spacing: 12) {
            Image(systemName: "power")
                .font(.system(size: 78, weight: .regular))
                .symbolEffect(.bounce, value: warning)
            Text(warning ? "Press Again" : "Sleep Mac").font(.tv(.caption1))
        }
        .foregroundStyle(focused && !warning ? .black : .white)
        .frame(width: Self.column, height: Self.row * 2 + Self.gap)
        .focusPlatter(RoundedRectangle(cornerRadius: 40, style: .continuous), focused: focused || warning,
                      color: warning ? Color(hex: "#FF453A") : .white)
        .contentShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .scaleEffect(focused ? 1.05 : 1)
        .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 22, y: 14)
        .onTapGesture { tv.activateControl(.sleepMac) }
    }

    private func tile(_ item: ControlCenterPanel.Item, _ panel: ControlCenterPanel, symbol: String,
                      title: String, detail: String, on: Bool) -> some View {
        let focused = panel.item == item
        return HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44)
                .opacity(on ? 1 : 0.7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.tv(.caption1))
                Text(detail).font(.tv(.caption2)).opacity(0.7)
                    .contentTransition(.numericText())
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .foregroundStyle(focused ? .black : .white)
        .frame(width: Self.column, height: Self.row)
        .focusPlatter(RoundedRectangle(cornerRadius: 32, style: .continuous), focused: focused)
        .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .scaleEffect(focused ? 1.05 : 1)
        .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 22, y: 14)
        .onTapGesture { tv.activateControl(item) }
    }

    private func round(_ item: ControlCenterPanel.Item, _ panel: ControlCenterPanel, symbol: String, on: Bool) -> some View {
        let focused = panel.item == item
        let size = (Self.column * 2 + Self.gap - Self.gap * 3) / 4
        return Image(systemName: symbol)
            .font(.system(size: 34, weight: .medium))
            .contentTransition(.symbolEffect(.replace))
            .opacity(on ? 1 : 0.7)
            .foregroundStyle(focused ? .black : .white)
            .frame(width: size, height: size)
            .focusPlatter(Circle(), focused: focused)
            .contentShape(Circle())
            .scaleEffect(focused ? 1.08 : 1)
            .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 18, y: 12)
            .onTapGesture { tv.activateControl(item) }
    }
}
