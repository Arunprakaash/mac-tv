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
    private var transitionGeneration = 0
    private var pendingDedicatedEntry = false
    private var relocationPending = false
    private var manualTargetID: String?
    private var manualRestoreFullscreen = false
    private var manualDedicatedEntry = false
    private var manualEntering = false
    private var fullscreenTargetID: String?
    private var fullscreenMoveRetries = 0
    private var movingWindow = false
    private var pairingFocus = 0
    private var screenChangeGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults

    init(window: NSWindow, tv: TVController, defaults: UserDefaults = .standard) {
        self.window = window
        self.tv = tv
        self.defaults = defaults
        tv.displayCoordinator.tvMode = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterFullScreen() }
        })
        observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didExitFullScreen() }
        })
    }

    private func toggleFullscreenWithWatchdog() {
        transitionGeneration += 1
        let generation = transitionGeneration
        window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.transitionGeneration == generation, self.transitioning else { return }
            self.trace("fullscreen transition timed out")
            self.transitioning = false
            self.pendingDedicatedEntry = false
            self.manualEntering = false
            self.manualTargetID = nil
            self.fullscreenTargetID = nil
            self.manualRestoreFullscreen = false
            self.manualDedicatedEntry = false
            self.relocationPending = false
            self.tv?.showToast("Fullscreen transition did not finish. Try choosing the display again.")
            self.tv?.objectWillChange.send()
        }
    }

    private func trace(_ event: String) {
        guard ProcessInfo.processInfo.environment["MACTV_DISPLAY_DEBUG"] == "1" else { return }
        NSLog("Mac TV display: %@ current=%@ preferred=%@ fullscreen=%@ transitioning=%@ moving=%@ target=%@ frame=%@", event,
              window.screen.map(id) ?? "none", preferredID ?? "automatic",
              String(window.styleMask.contains(.fullScreen)), String(transitioning), String(movingWindow),
              manualTargetID ?? "none", NSStringFromRect(window.frame))
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

    struct DisplayOption: Equatable {
        let id: String
        let name: String
        let current: Bool
        let preferred: Bool
    }

    var displayOptions: [DisplayOption] {
        NSScreen.screens.map { screen in
            DisplayOption(id: id(screen), name: screen.localizedName,
                          current: window.screen?.displayID == screen.displayID,
                          preferred: preferredID == id(screen))
        }
    }

    /// The pairing sheet's rows: phone access, the display (only when there's more than one), and Done.
    enum PairingRow { case access, display, done }

    var pairingRows: [PairingRow] { displayOptions.count > 1 ? [.access, .display, .done] : [.access, .done] }
    var pairingFocusedRow: PairingRow { pairingRows[min(pairingFocus, pairingRows.count - 1)] }

    func resetPairingFocus() { pairingFocus = 0 }

    /// The display after (or before) `current`, wrapping around.
    static func steppedDisplay(_ ids: [String], from current: String?, step: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        let at = current.flatMap { ids.firstIndex(of: $0) } ?? 0
        return ids[((at + step) % ids.count + ids.count) % ids.count]
    }

    /// Moves Mac TV to the next connected display.
    func stepDisplay(_ step: Int) {
        let options = displayOptions
        let current = options.first(where: \.current)?.id ?? preferredID
        if let next = Self.steppedDisplay(options.map(\.id), from: current, step: step) { _ = chooseDisplay(id: next) }
    }

    func handlePairing(_ command: RemoteCommand) {
        let rows = pairingRows
        pairingFocus = min(pairingFocus, rows.count - 1)
        let row = rows[pairingFocus]
        switch command {
        case .move(.up): pairingFocus = max(0, pairingFocus - 1)
        case .move(.down): pairingFocus = min(rows.count - 1, pairingFocus + 1)
        // Left and right change the focused row's value, like a Settings row.
        case .move(let direction) where row == .access && (direction == .left || direction == .right):
            tv?.pairingGuest.toggle()
        case .move(.left) where row == .display: stepDisplay(-1)
        case .move(.right) where row == .display: stepDisplay(1)
        case .select:
            switch row {
            case .access: tv?.pairingGuest.toggle()
            case .display: stepDisplay(1)
            case .done: tv?.pairing = false
            }
        case .back: tv?.pairing = false
        default: return
        }
        tv?.objectWillChange.send()
    }

    @discardableResult
    func chooseDisplay(id displayID: String) -> Bool {
        guard NSScreen.screens.contains(where: { id($0) == displayID }) else { return false }
        defaults.set(displayID, forKey: "preferredTVDisplay")
        trace("choose")
        if !transitioning, !movingWindow, window.screen.map({ id($0) }) == displayID {
            tv?.objectWillChange.send()
            return true
        }
        manualTargetID = displayID
        fullscreenMoveRetries = 0
        manualRestoreFullscreen = manualRestoreFullscreen || window.styleMask.contains(.fullScreen) || enabled
        manualDedicatedEntry = manualDedicatedEntry || enabled
        tv?.objectWillChange.send()
        performManualMove()
        return true
    }

    private func performManualMove() {
        guard let targetID = manualTargetID, !transitioning, !movingWindow else { return }
        guard let target = NSScreen.screens.first(where: { id($0) == targetID }) else {
            finishManualMoveFailure("The selected display disconnected.")
            return
        }
        if window.styleMask.contains(.fullScreen) {
            transitioning = true
            trace("request exit fullscreen")
            toggleFullscreenWithWatchdog()
        } else {
            movingWindow = true
            moveWindow(to: target)
            confirmManualMove(targetID: targetID, attempt: 0)
        }
    }

    private func confirmManualMove(targetID: String, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.trace("confirm move attempt \(attempt)")
            guard self.manualTargetID == targetID else {
                self.movingWindow = false
                self.performManualMove()
                return
            }
            guard let target = NSScreen.screens.first(where: { self.id($0) == targetID }) else {
                self.finishManualMoveFailure("The selected display disconnected.")
                return
            }
            if self.window.screen?.displayID == target.displayID {
                self.movingWindow = false
                self.manualTargetID = nil
                self.tv?.objectWillChange.send()
                if self.manualRestoreFullscreen {
                    self.manualRestoreFullscreen = false
                    self.manualEntering = true
                    self.fullscreenTargetID = targetID
                    self.pendingDedicatedEntry = self.manualDedicatedEntry
                    self.manualDedicatedEntry = false
                    self.transitioning = true
                    self.trace("request enter fullscreen")
                    self.toggleFullscreenWithWatchdog()
                }
            } else if attempt < 9 {
                self.moveWindow(to: target)
                self.confirmManualMove(targetID: targetID, attempt: attempt + 1)
            } else {
                self.finishManualMoveFailure("Could not move Mac TV to the selected display.")
            }
        }
    }

    private func finishManualMoveFailure(_ message: String) {
        movingWindow = false
        manualTargetID = nil
        let restore = manualRestoreFullscreen
        let dedicated = manualDedicatedEntry
        manualRestoreFullscreen = false
        manualDedicatedEntry = false
        trace("move failure: \(message)")
        tv?.showToast(message)
        tv?.objectWillChange.send()
        guard restore, !window.styleMask.contains(.fullScreen) else { return }
        if window.screen == nil, let fallback = NSScreen.main ?? NSScreen.screens.first {
            moveWindow(to: fallback)
        }
        manualEntering = true
        fullscreenTargetID = nil
        pendingDedicatedEntry = dedicated
        transitioning = true
        toggleFullscreenWithWatchdog()
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
            toggleFullscreenWithWatchdog()
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
        if transitioning || movingWindow {
            relocationPending = true
            return
        }
        if window.styleMask.contains(.fullScreen), window.screen?.displayID == target.displayID { return }
        // Use the same exit, move, verify and re-enter sequence as an explicit display choice.
        manualTargetID = id(target)
        fullscreenMoveRetries = 0
        manualRestoreFullscreen = true
        manualDedicatedEntry = true
        relocationPending = false
        performManualMove()
    }

    private func moveWindow(to screen: NSScreen) {
        let area = screen.visibleFrame
        let original = window.frame.size
        let scale = min(1, area.width / max(original.width, 1), area.height / max(original.height, 1))
        let size = NSSize(width: original.width * scale, height: original.height * scale)
        window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
        trace("set frame for \(id(screen))")
    }

    private func didEnterFullScreen() {
        transitionGeneration += 1
        trace("did enter fullscreen")
        let wasDedicatedEntry = pendingDedicatedEntry
        pendingDedicatedEntry = false
        let wasManualEntry = manualEntering
        manualEntering = false
        let enteredTarget = fullscreenTargetID
        fullscreenTargetID = nil
        // didEnter arrives before macOS has always finished settling its Space animation.
        // Serialize any next toggle and check the final screen after that settling period.
        transitioning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.transitioning = false
            self.trace("settled fullscreen entry")
            self.tv?.objectWillChange.send()
            if self.manualTargetID != nil { self.performManualMove(); return }
            if wasDedicatedEntry && !self.enabled {
                self.transitioning = true
                self.toggleFullscreenWithWatchdog()
                return
            }
            if wasManualEntry, let enteredTarget,
               self.window.screen.map({ self.id($0) }) != enteredTarget {
                if self.fullscreenMoveRetries < 2,
                   NSScreen.screens.contains(where: { self.id($0) == enteredTarget }) {
                    self.fullscreenMoveRetries += 1
                    self.manualTargetID = enteredTarget
                    self.manualRestoreFullscreen = true
                    self.manualDedicatedEntry = wasDedicatedEntry && self.enabled
                    self.performManualMove()
                } else {
                    self.fullscreenMoveRetries = 0
                    self.tv?.showToast("Could not move fullscreen Mac TV to the selected display.")
                }
                return
            }
            self.fullscreenMoveRetries = 0
            if self.enabled && self.relocationPending {
                self.relocationPending = false
                self.reconcileScreen()
            }
        }
    }

    private func didExitFullScreen() {
        transitionGeneration += 1
        trace("did exit fullscreen")
        transitioning = false
        tv?.objectWillChange.send()
        if manualTargetID != nil {
            transitioning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.transitioning = false
                self.trace("settled fullscreen exit")
                self.performManualMove()
            }
            return
        }
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
    private var tvMode: TVMode? { displayCoordinator.tvMode }
    var availableTVDisplays: [TVMode.DisplayOption] { tvMode?.displayOptions ?? [] }
    var displaySetup: [[String: Any]] {
        availableTVDisplays.map { ["id": $0.id, "name": $0.name, "current": $0.current, "preferred": $0.preferred] }
    }
    var pairingRows: [TVMode.PairingRow] { tvMode?.pairingRows ?? [.access, .done] }
    var pairingFocusedRow: TVMode.PairingRow { tvMode?.pairingFocusedRow ?? .access }
    func stepPairingDisplay() { tvMode?.stepDisplay(1) }
    func handlePairing(_ command: RemoteCommand) { tvMode?.handlePairing(command) }
    @discardableResult func selectTVDisplay(id: String) -> Bool { tvMode?.chooseDisplay(id: id) ?? false }
    var dedicatedTVMode: Bool { tvMode?.enabled ?? false }
    var preferredTVDisplayName: String { tvMode?.preferredName ?? "Automatic" }
    var launchAtLogin: Bool { tvMode?.loginEnabled ?? false }
    var loginNeedsApproval: Bool { tvMode?.loginStatus == .requiresApproval }
    func setDedicatedTVMode(_ enabled: Bool) { tvMode?.setEnabled(enabled) }
    func stepTVDisplay(_ step: Int, wrap: Bool = false) { tvMode?.stepDisplay(step, wrap: wrap) }
    func setLaunchAtLogin(_ enabled: Bool) { tvMode?.setLoginEnabled(enabled) }
}
