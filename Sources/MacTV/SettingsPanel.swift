import SwiftUI

/// The TV's Settings sheet: the phone remote's QR code and the same settings as the remote's
/// TV controls, driven by the D-pad, the keyboard or the mouse.
struct SettingsPanel: Equatable {
    enum Row: Int, CaseIterable {
        case phoneRemote, sleepTimer, autoSkip, autoNext, keepMacAwake, lidOverride, screenOff, sleepMac
    }

    var row: Row = .phoneRemote
    /// Sleep Mac asks for a second press, like the phone remote's double tap.
    var confirmingSleep = false
}

extension TVController {
    static let sleepTimerSteps = [0, 15, 30, 60, 90]

    /// Minutes left on the sleep timer; 0 when it's off.
    var sleepMinutesLeft: Int {
        sleepAt.map { max(1, Int(($0.timeIntervalSinceNow / 60).rounded(.up))) } ?? 0
    }

    func openSettings() {
        settings = SettingsPanel()
        // Nothing to set before there's a remote: go straight to the QR code.
        if !phonePaired { pairing = true }
    }

    func handleSettings(_ command: RemoteCommand) {
        guard var panel = settings else { return }
        let rows = SettingsPanel.Row.allCases
        let index = panel.row.rawValue
        if case .select = command {} else { panel.confirmingSleep = false }
        switch command {
        case .back:
            settings = nil
            return
        case .move(.up):
            panel.row = rows[max(0, index - 1)]
        case .move(.down):
            panel.row = rows[min(rows.count - 1, index + 1)]
        case .move(let direction) where direction == .left || direction == .right:
            settings = panel
            adjustSetting(panel.row, on: direction == .right)
            return
        case .select:
            settings = panel
            activateSetting(panel.row)
            return
        default:
            break
        }
        settings = panel
    }

    /// Left and right: step the sleep timer, or switch a setting off and on.
    private func adjustSetting(_ row: SettingsPanel.Row, on: Bool) {
        switch row {
        case .sleepTimer: stepSleepTimer(by: on ? 1 : -1, wrap: false)
        case .autoSkip: autoSkip = on
        case .autoNext: autoNext = on
        case .keepMacAwake: keepMacAwake = on
        case .lidOverride: lidOverride = on
        default: return
        }
        objectWillChange.send()
    }

    func activateSetting(_ row: SettingsPanel.Row) {
        settings?.row = row
        switch row {
        case .phoneRemote: pairing = true
        case .sleepTimer: stepSleepTimer(by: 1, wrap: true)
        case .autoSkip: autoSkip.toggle()
        case .autoNext: autoNext.toggle()
        case .keepMacAwake: keepMacAwake.toggle()
        case .lidOverride: lidOverride.toggle()
        case .screenOff: SystemControl.displayOff()
        case .sleepMac:
            if settings?.confirmingSleep == true {
                goHome()
                SystemControl.sleepNow()
            } else {
                settings?.confirmingSleep = true
            }
        }
        objectWillChange.send()
    }

    /// Moves the sleep timer to the next or previous step: Off, 15, 30, 60, 90 minutes.
    private func stepSleepTimer(by step: Int, wrap: Bool) {
        let steps = Self.sleepTimerSteps
        let current = steps.firstIndex { $0 >= sleepMinutesLeft } ?? 0
        var next = current + step
        next = wrap ? (next + steps.count) % steps.count : min(max(next, 0), steps.count - 1)
        guard next != current else { return }
        setSleepTimer(minutes: steps[next])
    }
}

struct SettingsSheet: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let panel = tv.settings ?? SettingsPanel()
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(.system(size: 52, weight: .heavy)).tracking(-1)
                .padding(.bottom, 8)

            group("Remote")
            row(.phoneRemote, "Phone remote", panel) {
                trailing(tv.phonePaired ? "Show QR code" : "Set up", chevron: true)
            }

            group("Watching")
            row(.sleepTimer, "Sleep timer", panel) {
                let minutes = tv.sleepMinutesLeft
                HStack(spacing: 14) {
                    if panel.row == .sleepTimer { Image(systemName: "chevron.left").opacity(0.6) }
                    Text(minutes == 0 ? "Off" : "\(minutes) min left").monospacedDigit()
                    if panel.row == .sleepTimer { Image(systemName: "chevron.right").opacity(0.6) }
                }
                .font(.system(size: 24, weight: .semibold))
            }
            row(.autoSkip, "Skip intros and recaps", panel) { SettingSwitch(on: tv.autoSkip) }
            row(.autoNext, "Play next episode automatically", panel) { SettingSwitch(on: tv.autoNext) }

            group("Power")
            Text(tv.lidStatus)
                .font(.system(size: 21))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            row(.keepMacAwake, "Keep Mac awake while Mac TV is open", panel) { SettingSwitch(on: tv.keepMacAwake) }
            row(.lidOverride, "Stay awake with lid closed", panel) { SettingSwitch(on: tv.lidOverride) }
            row(.screenOff, "Turn screen off", panel) { EmptyView() }
            row(.sleepMac, panel.confirmingSleep ? "Press again to sleep the Mac" : "Sleep Mac", panel) { EmptyView() }
        }
        .padding(56)
        .frame(width: 1100, alignment: .leading)
        .background(Color(hex: "#282A32").opacity(0.9), in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 44, style: .continuous).strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.5), radius: 50, y: 30)
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(.easeOut(duration: 0.18), value: panel)
    }

    private func group(_ title: String) -> some View {
        Text(title).font(.system(size: 20, weight: .bold)).tracking(1).textCase(.uppercase).opacity(0.6)
            .padding(.top, 12)
            .padding(.horizontal, 4)
    }

    private func trailing(_ text: String, chevron: Bool) -> some View {
        HStack(spacing: 10) {
            Text(text)
            if chevron { Image(systemName: "chevron.right") }
        }
        .font(.system(size: 24, weight: .semibold))
        .opacity(0.7)
    }

    private func row<Trailing: View>(_ row: SettingsPanel.Row, _ title: String, _ panel: SettingsPanel,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        let focused = panel.row == row
        let warning = row == .sleepMac && panel.confirmingSleep
        return HStack(spacing: 20) {
            Text(title).font(.system(size: 27, weight: .semibold))
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
        .background(warning ? Color(hex: "#FF6B6B").opacity(0.3) : .white.opacity(focused ? 0.16 : 0.07),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(.white.opacity(focused ? 0.9 : 0), lineWidth: 3))
        .contentShape(Rectangle())
        .onTapGesture { tv.activateSetting(row) }
    }
}

/// An on/off switch drawn like the phone remote's.
struct SettingSwitch: View {
    let on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Color(hex: "#3DDC84") : .white.opacity(0.22))
            .frame(width: 64, height: 36)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 28, height: 28).padding(4)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
            .animation(.easeOut(duration: 0.15), value: on)
    }
}
