import SwiftUI

/// The TV's Settings sheet: the phone remote's QR code and the same settings as the remote's
/// TV controls, driven by the D-pad, the keyboard or the mouse.
struct SettingsPanel: Equatable {
    enum Row: Int, CaseIterable {
        case phoneRemote, controller, arrangeApps, topShelfPreferences, playbackCheck, dedicatedTV, preferredDisplay, launchAtLogin, sleepTimer, autoSkip, autoNext, keepMacAwake, lidOverride, screenOff, sleepMac
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
        case .dedicatedTV: setDedicatedTVMode(on)
        case .preferredDisplay: stepTVDisplay(on ? 1 : -1)
        case .launchAtLogin: setLaunchAtLogin(on)
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
        case .controller:
            showToast(controller == nil ? "Pair a controller in System Settings › Bluetooth" : "Press its Menu button any time to come home")
        case .arrangeApps: openOrganizer()
        case .topShelfPreferences: openTopShelfPreferences()
        case .playbackCheck: openPlaybackCheck()
        case .dedicatedTV: setDedicatedTVMode(!dedicatedTVMode)
        case .preferredDisplay: stepTVDisplay(1, wrap: true)
        case .launchAtLogin: setLaunchAtLogin(!launchAtLogin)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var focusSpace

    var body: some View {
        let panel = tv.settings ?? SettingsPanel()
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(.system(size: 52, weight: .heavy)).tracking(-1)
                .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        group("Remote")
                        row(.phoneRemote, "Phone remote", panel) {
                            trailing(tv.phonePaired ? "Show QR code" : "Set up", chevron: true)
                        }
                        row(.controller, "Game controller", panel) {
                            if let controller = tv.controller {
                                HStack(spacing: 10) {
                                    Text(controller.name)
                                    if controller.battery != nil || controller.charging { Image(systemName: controller.batterySymbol) }
                                }
                                .font(.system(size: 24, weight: .semibold)).opacity(0.7)
                            } else {
                                trailing("None connected", chevron: false)
                            }
                        }

                        row(.arrangeApps, "Arrange Apps", panel) {
                            trailing("Order and favourites", chevron: true)
                        }

                        row(.topShelfPreferences, "Top Shelf", panel) { trailing("Choose sources", chevron: true) }
                        row(.playbackCheck, "Playback check", panel) { trailing("Check playback", chevron: true) }

                        group("Dedicated TV")
                        row(.dedicatedTV, tv.dedicatedTVMode ? "Exit TV mode" : "Enter TV mode", panel) {
                            SettingSwitch(on: tv.dedicatedTVMode)
                        }
                        row(.preferredDisplay, "Preferred display", panel) {
                            trailing(tv.preferredTVDisplayName, chevron: true)
                        }
                        row(.launchAtLogin, "Launch at login", panel) {
                            if tv.loginNeedsApproval { trailing("Approval needed", chevron: false) }
                            else { SettingSwitch(on: tv.launchAtLogin) }
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
                    .padding(8)
                }
                .frame(height: min(720, max(300, canvas.height - 320)))
                .onAppear { proxy.scrollTo(panel.row, anchor: .center) }
                .onChange(of: panel.row) { _, row in
                    withAnimation(reduceMotion ? nil : Motion.focus) { proxy.scrollTo(row, anchor: .center) }
                }
            }
        }
        .padding(56)
        .frame(width: 1100, alignment: .leading)
        .tvGlass(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.focus, value: panel)
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
        // tvOS focus: a bright white platter with dark text; Sleep Mac turns red to confirm.
        .foregroundStyle(focused && !warning ? .black : .white)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            if focused {
                // One platter that glides from row to row as focus moves, like tvOS.
                shape.fill(warning ? Color(hex: "#FF453A") : .white)
                    .matchedGeometryEffect(id: "focus", in: focusSpace)
            } else {
                shape.fill(.white.opacity(0.08))
            }
        }
        .scaleEffect(focused ? 1.02 : 1)
        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 14, y: 8)
        .animation(Motion.focus, value: focused)
        .contentShape(Rectangle())
        .onTapGesture { tv.activateSetting(row) }
        .id(row)
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
            .animation(.snappy(duration: 0.2), value: on)
    }
}
