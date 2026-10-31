import AppKit
import IOKit.graphics
import ServiceManagement

/// Window and login-item behavior for the optional dedicated TV setup.
@MainActor
final class TVMode {
    private let window: NSWindow
    private weak var tv: TVController?
    private var normalFrame: NSRect?
    private var transitioning = false
    private var relocationPending = false
    private var screenChangeGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private let defaults = UserDefaults.standard

    init(window: NSWindow, tv: TVController) {
        self.window = window
        self.tv = tv
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterFullScreen() }
        })
        observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didExitFullScreen() }
        })
    }

    var enabled: Bool { defaults.bool(forKey: "dedicatedTVMode") }
    var preferredID: String? { defaults.string(forKey: "preferredTVDisplay") }
    var loginStatus: SMAppService.Status { SMAppService.mainApp.status }
    var loginEnabled: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    private func id(_ screen: NSScreen) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(screen.displayID)?.takeRetainedValue() else {
            return "display-\(screen.displayID)"
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    var preferredName: String {
        guard let preferredID else { return "Automatic" }
        return NSScreen.screens.first(where: { id($0) == preferredID })?.localizedName ?? "Display disconnected"
    }

    func stepDisplay(_ step: Int, wrap: Bool) {
        let screens = NSScreen.screens
        let choices: [String?] = [nil] + screens.map { id($0) as String? }
        // Keep a disconnected preference until the user explicitly chooses another display.
        let current = choices.firstIndex { $0 == preferredID } ?? 0
        var next = current + step
        next = wrap ? (next + choices.count) % choices.count : min(max(next, 0), choices.count - 1)
        if let choice = choices[next] { defaults.set(choice, forKey: "preferredTVDisplay") }
        else { defaults.removeObject(forKey: "preferredTVDisplay") }
        tv?.objectWillChange.send()
        if enabled { reconcileScreen() }
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        defaults.set(value, forKey: "dedicatedTVMode")
        tv?.objectWillChange.send()
        if value {
            normalFrame = window.frame
            reconcileScreen()
        } else if window.styleMask.contains(.fullScreen) && !transitioning {
            relocationPending = false
            transitioning = true
            window.toggleFullScreen(nil)
        } else if !transitioning {
            restoreNormalFrame()
        }
    }

    func start() {
        guard enabled else { return }
        normalFrame = window.frame
        // Allow the normal window to be presented before requesting a Space transition.
        DispatchQueue.main.async { [weak self] in self?.reconcileScreen() }
    }

    func setLoginEnabled(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval {
                tv?.showToast("Allow Mac TV in System Settings › General › Login Items")
            }
        } catch {
            tv?.showToast("Could not change login item: \(error.localizedDescription)")
        }
        tv?.objectWillChange.send()
    }

    func screensChanged() {
        screenChangeGeneration += 1
        let generation = screenChangeGeneration
        // Display arrangements can produce several notifications while HDMI settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, generation == self.screenChangeGeneration else { return }
            self.tv?.objectWillChange.send()
            if self.enabled { self.reconcileScreen() }
        }
    }

    var playbackScreen: NSScreen? { targetScreen }

    private var targetScreen: NSScreen? {
        if let preferredID, let match = NSScreen.screens.first(where: { id($0) == preferredID }) { return match }
        return NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) == 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func reconcileScreen() {
        guard enabled, let target = targetScreen else { return }
        if transitioning { relocationPending = true; return }
        if window.styleMask.contains(.fullScreen) {
            guard window.screen?.displayID != target.displayID else { return }
            relocationPending = true
            transitioning = true
            window.toggleFullScreen(nil)
        } else {
            moveWindow(to: target)
            transitioning = true
            window.toggleFullScreen(nil)
        }
    }

    private func moveWindow(to screen: NSScreen) {
        let area = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }

    private func didEnterFullScreen() {
        transitioning = false
        if !enabled {
            transitioning = true
            window.toggleFullScreen(nil)
        } else if relocationPending {
            relocationPending = false
            reconcileScreen()
        }
    }

    private func didExitFullScreen() {
        transitioning = false
        if enabled {
            // macOS can exit full screen during display removal. Keep the user's
            // setting and recover on the available screen until they choose Exit TV mode.
            relocationPending = false
            reconcileScreen()
        } else {
            relocationPending = false
            restoreNormalFrame()
        }
    }

    private func restoreNormalFrame() {
        guard let frame = normalFrame else { return }
        // Don't restore an inaccessible window after the display has been unplugged.
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            window.setFrame(frame, display: true)
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            moveWindow(to: screen)
        }
        normalFrame = nil
    }
}

extension TVController {
    private var tvMode: TVMode? { (NSApp.delegate as? AppDelegate)?.tvMode }
    var dedicatedTVMode: Bool { tvMode?.enabled ?? false }
    var preferredTVDisplayName: String { tvMode?.preferredName ?? "Automatic" }
    var launchAtLogin: Bool { tvMode?.loginEnabled ?? false }
    var loginNeedsApproval: Bool { tvMode?.loginStatus == .requiresApproval }
    func setDedicatedTVMode(_ enabled: Bool) { tvMode?.setEnabled(enabled) }
    func stepTVDisplay(_ step: Int, wrap: Bool = false) { tvMode?.stepDisplay(step, wrap: wrap) }
    func setLaunchAtLogin(_ enabled: Bool) { tvMode?.setLoginEnabled(enabled) }
}
