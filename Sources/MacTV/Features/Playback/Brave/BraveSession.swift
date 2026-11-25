import AppKit
import ApplicationServices
import Carbon

/// Owns one app-mode window of a Chromium browser: the site with no tabs or toolbar, as an installed web
/// app opens, using that browser's own profile, sign-ins, extensions and ad blocking (Brave's Shields).
/// The window is found, placed and focused through Accessibility; the browser needs no Automation access.
@MainActor
final class BrowserSession {
    enum SessionError: LocalizedError {
        case invalidURL, unavailable, noWindow, permission, placement, focus, closing, eventCreation
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Only HTTP and HTTPS addresses can be opened in a browser."
            case .unavailable: return "The browser is unavailable or has quit."
            case .noWindow: return "Mac TV's browser window is no longer open."
            case .permission: return "Allow Mac TV in Privacy & Security > \(BrowserSession.permissionPane) to open and control the browser window."
            case .placement: return "Could not place the browser window on the selected display. Check \(BrowserSession.permissionPane) in Privacy & Security and try again."
            case .focus: return "Could not bring the browser window to the front. Try again."
            case .closing: return "Could not close Mac TV's browser window."
            case .eventCreation: return "The remote input event could not be created."
            }
        }
    }

    /// The Privacy & Security pane that grants Accessibility access: renamed in macOS 27 (Golden Gate).
    nonisolated static var permissionPane: String {
        paneName(for: ProcessInfo.processInfo.operatingSystemVersion)
    }

    nonisolated static func paneName(for version: OperatingSystemVersion) -> String {
        version.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }

    struct KeyStroke: Equatable {
        let code: CGKeyCode
        var flags: CGEventFlags = []
    }

    let bundleID: String
    let name: String
    /// PID of the browser process that owns Mac TV's app-mode window, once open.
    var processIdentifier: pid_t? { application?.processIdentifier }
    private var application: NSRunningApplication?
    private var window: AXUIElement?
    private var cachedBounds: CGRect?
    private var lastBoundsRead = Date.distantPast
    private var pointer: CGPoint?
    private var validatedFocusedWindow: AXUIElement?
    private var lastFocusValidation: TimeInterval = 0
    private var invalidated = false
    /// Called once when the window goes away without Mac TV closing it: closed in the browser, or the browser quit.
    var onClose: (() -> Void)?
    private var observer: AXObserver?
    /// The observer's callback finds the session through a raw pointer, so the session keeps itself alive
    /// while it's watched and lets go in `stopWatching`.
    private var watchedSelf: Unmanaged<BrowserSession>?
    private var terminationObserver: NSObjectProtocol?

    init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    /// YouTube's TV page expects a TV user agent; a browser should use the normal desktop page.
    static func streamingURL(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { throw SessionError.invalidURL }
        if (host == "youtube.com" || host == "www.youtube.com") &&
            (url.path == "/tv" || url.path.hasPrefix("/tv/")) {
            return URL(string: "https://www.youtube.com/")!
        }
        return url
    }

    static func keyStroke(for command: RemoteCommand) -> KeyStroke? {
        switch command {
        case .move(.up), .previousControl: return KeyStroke(code: 48, flags: .maskShift)
        case .move(.down), .nextControl: return KeyStroke(code: 48)
        case .move(.left): return KeyStroke(code: 123)
        case .move(.right): return KeyStroke(code: 124)
        case .select: return KeyStroke(code: 36)
        case .back: return KeyStroke(code: 53)
        case .playPause: return KeyStroke(code: 49)
        case .seek(let forward): return KeyStroke(code: forward ? 124 : 123)
        case .deleteBackward: return KeyStroke(code: 51)
        case .browserFullscreen: return KeyStroke(code: 3, flags: [.maskControl, .maskCommand])
        default: return nil
        }
    }

    /// Opens the site with `--app`, the way a Chromium browser opens an installed web app. A second launch
    /// hands the flag to the copy that's already running, so the window joins the browser's usual profile.
    func open(_ url: URL) async throws {
        let destination = try Self.streamingURL(url)
        guard !invalidated else { throw CancellationError() }
        if window != nil { throw SessionError.noWindow }
        guard AXIsProcessTrusted() else { throw SessionError.permission }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw SessionError.unavailable
        }
        let before = Self.windows(of: bundleID).map(\.window)
        let config = NSWorkspace.OpenConfiguration()
        // Mac TV keeps the launch cover pinned; activate only after fit/fullscreen.
        config.activates = false
        config.createsNewApplicationInstance = true
        config.arguments = ["--app=\(destination.absoluteString)"]
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        for _ in 0..<60 {
            guard !invalidated else { throw CancellationError() }
            // Front to back: the app window opens in front of any windows the browser restores.
            if let new = Self.windows(of: bundleID).first(where: { item in !before.contains { CFEqual($0, item.window) } }) {
                application = new.app
                window = new.window
                watch(new.window, of: new.app)
                return
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw SessionError.noWindow
    }

    /// The browser's standard windows, front to back, across its running copies.
    private static func windows(of bundleID: String) -> [(app: NSRunningApplication, window: AXUIElement)] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }.flatMap { app in
            var list: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                                kAXWindowsAttribute as CFString, &list) == .success,
                  let windows = list as? [AXUIElement] else { return [(app: NSRunningApplication, window: AXUIElement)]() }
            return windows.filter { attribute($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole as String }
                .map { (app: app, window: $0) }
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// Places the window on the TV, checks it arrived, then makes it full screen like Mac TV's own player.
    func fit(to screen: NSScreen) async throws {
        guard AXIsProcessTrusted() else { throw SessionError.permission }
        guard let app = application, !app.isTerminated, let window else { throw SessionError.unavailable }
        let screenID = screen.displayID
        for _ in 0..<40 {
            guard !invalidated, !app.isTerminated else { throw CancellationError() }
            guard let target = NSScreen.screens.first(where: { $0.displayID == screenID }) else { throw SessionError.placement }
            let area = target.visibleFrame
            let primaryHeight = NSScreen.screens.first?.frame.height ?? area.maxY
            var origin = CGPoint(x: area.minX, y: primaryHeight - area.maxY)
            var size = CGSize(width: area.width, height: area.height)
            if let point = AXValueCreate(.cgPoint, &origin), let sizeValue = AXValueCreate(.cgSize, &size),
               AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, point) == .success,
               AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success {
                try await Task.sleep(for: .milliseconds(150))
                guard !invalidated, !app.isTerminated else { throw CancellationError() }
                var actual = CGPoint.zero
                if let position = Self.attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                   AXValueGetValue(position as! AXValue, .cgPoint, &actual),
                   abs(actual.x - origin.x) < 12, abs(actual.y - origin.y) < 12 {
                    // Best effort: a window that can't go full screen still fills the display.
                    _ = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
                    cachedBounds = nil
                    pointer = nil
                    validatedFocusedWindow = nil
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw SessionError.placement
    }

    func activate() throws {
        validatedFocusedWindow = nil
        lastFocusValidation = 0
        guard let app = application, !app.isTerminated else { throw SessionError.unavailable }
        guard let window else { throw SessionError.noWindow }
        _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                         kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        // Bringing an app forward settles within a few frames.
        for _ in 0..<10 {
            if let focused = focusedWindow(of: app), CFEqual(focused, window) {
                validatedFocusedWindow = focused
                lastFocusValidation = ProcessInfo.processInfo.systemUptime
                return
            }
            usleep(20_000)
        }
        throw SessionError.focus
    }

    private func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        guard let value = Self.attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func activateForPointer(_ app: NSRunningApplication) throws {
        let age = ProcessInfo.processInfo.systemUptime - lastFocusValidation
        if age >= 0, age < 0.25, app.isActive, let owned = validatedFocusedWindow,
           let focused = focusedWindow(of: app), CFEqual(owned, focused) { return }
        try activate()
    }

    /// Watches for the window closing or the browser quitting, so Mac TV can come back in front,
    /// as it does when the built-in player closes.
    private func watch(_ window: AXUIElement, of app: NSRunningApplication) {
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let session = Unmanaged<BrowserSession>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { session.windowWentAway() }
        }
        if AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created {
            let retained = Unmanaged.passRetained(self)
            if AXObserverAddNotification(created, window, kAXUIElementDestroyedNotification as CFString,
                                         retained.toOpaque()) == .success {
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
                observer = created
                watchedSelf = retained
            } else {
                retained.release()
            }
        }
        Log.playback.notice("Watching \(self.name, privacy: .public) window: \(self.observer == nil ? "observer refused" : "observer set", privacy: .public)")
        let pid = app.processIdentifier
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let quit = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard quit?.processIdentifier == pid else { return }
            MainActor.assumeIsolated { self?.windowWentAway() }
        }
    }

    private func stopWatching() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        watchedSelf?.release()
        watchedSelf = nil
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        terminationObserver = nil
    }

    func windowWentAway() {
        guard !invalidated else { return }
        invalidated = true
        window = nil
        application = nil
        stopWatching()
        let handler = onClose
        onClose = nil
        handler?()
    }

    /// Closes only the window this session opened, with its own close button.
    func close() throws {
        invalidated = true
        stopWatching()
        onClose = nil
        validatedFocusedWindow = nil
        lastFocusValidation = 0
        cachedBounds = nil
        pointer = nil
        guard let window else { return }
        self.window = nil
        guard let app = application, !app.isTerminated else { throw SessionError.unavailable }
        application = nil
        guard let button = Self.attribute(window, kAXCloseButtonAttribute) else { throw SessionError.noWindow }
        guard CFGetTypeID(button) == AXUIElementGetTypeID(),
              AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success else {
            throw SessionError.closing
        }
    }

    /// Returns false for commands managed by Mac TV rather than the browser.
    @discardableResult
    func handle(_ command: RemoteCommand) throws -> Bool {
        guard let app = application, !app.isTerminated, window != nil else { throw SessionError.noWindow }
        guard AXIsProcessTrusted() else { throw SessionError.permission }
        if let key = Self.keyStroke(for: command) {
            try activate()
            try postKey(key, to: app.processIdentifier)
            return true
        }
        switch command {
        case .text(let text):
            try activate()
            for character in text {
                var units = Array(String(character).utf16)
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { throw SessionError.eventCreation }
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                    event.postToPid(app.processIdentifier)
                }
            }
            return true
        case .pointer(let dx, let dy):
            guard dx.isFinite, dy.isFinite else { return true }
            try activateForPointer(app)
            let bounds = try windowBounds()
            let current = pointer ?? CGPoint(x: bounds.midX, y: bounds.midY)
            let next = CGPoint(x: min(max(current.x + dx, bounds.minX + 1), bounds.maxX - 1),
                               y: min(max(current.y + dy, bounds.minY + 1), bounds.maxY - 1))
            pointer = next
            CGWarpMouseCursorPosition(next)
            NSCursor.setHiddenUntilMouseMoves(false)
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: next, mouseButton: .left) else { throw SessionError.eventCreation }
            event.postToPid(app.processIdentifier)
            return true
        case .click:
            try activate()
            let bounds = try windowBounds(force: true)
            let p = pointer ?? CGPoint(x: bounds.midX, y: bounds.midY)
            guard bounds.contains(p) else { pointer = nil; throw SessionError.noWindow }
            // A real click where the pointer is: the browser ignores clicks posted to its process, and one
            // without a click count. The window was just brought in front, so the click lands on it.
            CGWarpMouseCursorPosition(p)
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { throw SessionError.eventCreation }
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                event.post(tap: .cghidEventTap)
            }
            return true
        case .scroll(let dy):
            guard dy.isFinite else { return true }
            try activateForPointer(app)
            let bounds = try windowBounds()
            let p = pointer.flatMap { bounds.contains($0) ? $0 : nil } ?? CGPoint(x: bounds.midX, y: bounds.midY)
            let amount = Int32(max(-1000, min(1000, -dy)))
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0) else { throw SessionError.eventCreation }
            // Scrolling goes to whatever is under the cursor, so it's posted there like a trackpad's.
            CGWarpMouseCursorPosition(p)
            event.location = p
            event.post(tap: .cghidEventTap)
            return true
        default: return false
        }
    }

    private func postKey(_ key: KeyStroke, to pid: pid_t) throws {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: down) else { throw SessionError.eventCreation }
            event.flags = key.flags
            event.postToPid(pid)
        }
    }

    private func windowBounds(force: Bool = false) throws -> CGRect {
        if !force, let bounds = cachedBounds, Date().timeIntervalSince(lastBoundsRead) < 0.25 { return bounds }
        guard let window else { throw SessionError.noWindow }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = Self.attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let extent = Self.attribute(window, kAXSizeAttribute), CFGetTypeID(extent) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(extent as! AXValue, .cgSize, &size) else { throw SessionError.noWindow }
        let bounds = CGRect(origin: origin, size: size)
        guard bounds.width > 2, bounds.height > 2 else { throw SessionError.noWindow }
        cachedBounds = bounds
        lastBoundsRead = Date()
        return bounds
    }
}
