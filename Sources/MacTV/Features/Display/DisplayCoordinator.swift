import AppKit
import IOKit.pwr_mgt

/// Manages display power assertions, lid sleep overrides, and external screen configuration.
@MainActor
final class DisplayCoordinator: ObservableObject {
    weak var tv: TVController?
    weak var tvMode: TVMode?

    private let keepAwake = KeepAwake()
    private let macAwake = KeepAwake(kIOPMAssertionTypePreventUserIdleSystemSleep)
    private var powerTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lidGuard: Process?
    private static let lowBattery = 20

    @Published private(set) var power = PowerStatus()
    @Published private(set) var lidSleepOff = false
    @Published private(set) var displaysSleeping = false
    private var lastDisplayWakeRequest = -Double.infinity

    init(tv: TVController? = nil) {
        self.tv = tv
    }

    /// Prevent the Mac from sleeping automatically while Mac TV is open so the remote remains responsive.
    var keepMacAwake: Bool {
        get { UserDefaults.standard.bool(forKey: "keepMacAwake") }
        set { UserDefaults.standard.set(newValue, forKey: "keepMacAwake"); applyPower() }
    }

    /// Keep running with the lid closed even on battery or without a TV connected.
    var lidOverride: Bool {
        get { UserDefaults.standard.bool(forKey: "lidOverride") }
        set { UserDefaults.standard.set(newValue, forKey: "lidOverride"); applyPower() }
    }

    /// One line for the remote about what closing the lid will do.
    var lidStatus: String {
        if lidSleepOff {
            return power.onAC ? "Lid sleep is off while Mac TV is open. Keep the Mac somewhere ventilated."
                : "Lid sleep is off while Mac TV is open, on battery. It turns back on below \(Self.lowBattery)%."
        }
        if power.closedLidModeReady { return "You can close the lid: the TV and power are connected." }
        if !power.onAC { return "Closing the lid will sleep the Mac. Connect power, or turn on the option below." }
        return "Closing the lid will sleep the Mac. Connect the TV, or turn on the option below."
    }

    func startPowerManagement() {
        applyPower()
        // Often enough to win back the lid switch soon after powerd rewrites it.
        powerTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPower() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPower() }
        }
    }

    func stopPowerManagement() {
        powerTimer?.invalidate()
        macAwake.release()
        if lidSleepOff { releaseLid() }
    }

    func refreshPower() {
        let now = PowerStatus.current()
        if now != power {
            power = now
            tv?.objectWillChange.send()
        }
        guard lidSleepOff else { return }
        if let reason = lidOverrideStopReason() {
            lidOverride = false
            tv?.showToast(reason)
        } else {
            LidSleep.setPrevented(true)
        }
    }

    func applyPower() {
        power = PowerStatus.current()
        keepMacAwake ? macAwake.hold(reason: "Mac TV is open, so the phone remote can reach it") : macAwake.release()

        if lidOverride, lidSleepOff == false {
            if let reason = lidOverrideStopReason() {
                UserDefaults.standard.set(false, forKey: "lidOverride")
                tv?.showToast(reason)
            } else if LidSleep.setPrevented(true) {
                lidSleepOff = true
                lidGuard = LidSleep.startGuard()
            } else {
                UserDefaults.standard.set(false, forKey: "lidOverride")
                tv?.showToast("This Mac doesn't allow staying awake with the lid closed")
            }
        } else if !lidOverride, lidSleepOff {
            releaseLid()
        }
        tv?.objectWillChange.send()
    }

    private func releaseLid() {
        LidSleep.restore()
        lidGuard?.terminate()
        lidGuard = nil
        lidSleepOff = false
        tv?.objectWillChange.send()
    }

    /// Why the lid override has to stop now, if it does: a closed Mac that never sleeps can run
    /// its battery flat or overheat in a bag.
    private func lidOverrideStopReason() -> String? {
        if !power.onAC, let battery = power.battery, battery < Self.lowBattery {
            return "Battery low: closing the lid sleeps the Mac again"
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return "Mac is hot: closing the lid sleeps the Mac again"
        default: return nil
        }
    }

    func noteDisplaySleep(_ sleeping: Bool) {
        displaysSleeping = sleeping
        if sleeping { tv?.screensaverOff() }
        tv?.objectWillChange.send()
    }

    func wakeDisplays() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDisplayWakeRequest >= 0.5 else { return }
        if SystemControl.displayOn() { lastDisplayWakeRequest = now }
        else { tv?.showToast("The display wake request failed. Try Wake screen again.") }
    }

    func holdPlaybackKeepAwake(reason: String) {
        keepAwake.hold(reason: reason)
    }

    func releasePlaybackKeepAwake() {
        keepAwake.release()
    }

    var playbackScreen: NSScreen? {
        tvMode?.playbackScreen
            ?? tv?.window?.screen ?? NSScreen.screens.first { CGDisplayIsBuiltin($0.displayID) == 0 }
            ?? NSScreen.main
    }

    func resetPairingFocus() {
        tvMode?.resetPairingFocus()
    }

    /// Report current connected displays and refresh rates.
    var displayDiagnostics: [(name: String, width: Int, height: Int, refreshRate: Double)] {
        NSScreen.screens.compactMap { screen in
            guard let mode = CGDisplayCopyDisplayMode(screen.displayID) else { return nil }
            return (screen.localizedName, mode.pixelWidth, mode.pixelHeight, mode.refreshRate)
        }
    }
}

