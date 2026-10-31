import AppKit
import ApplicationServices
import Carbon

/// Owns one normal Brave window. Brave's own profile and Shields settings apply to it.
@MainActor
final class BraveSession {
    enum SessionError: LocalizedError {
        case invalidURL, unavailable, noWindow, permission, automationDenied, script(String), eventCreation
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Only HTTP and HTTPS streaming addresses can be opened in Brave."
            case .unavailable: return "Brave Browser is unavailable or has quit."
            case .noWindow: return "The Mac TV Brave window is no longer available."
            case .permission: return "Allow Mac TV to control your computer in Privacy & Security > Accessibility."
            case .automationDenied: return "Allow Mac TV to control Brave Browser in Privacy & Security > Automation > Mac TV."
            case .script(let message): return "Brave could not be controlled: \(message)"
            case .eventCreation: return "The remote input event could not be created."
            }
        }
    }

    struct KeyStroke: Equatable {
        let code: CGKeyCode
        var flags: CGEventFlags = []
    }

    private var application: NSRunningApplication?
    private var windowID: String?
    private var ownershipToken: String?
    private var cachedBounds: CGRect?
    private var lastBoundsRead = Date.distantPast
    private var pointer: CGPoint?
    private var compiledScript: NSAppleScript?
    private var validatedFocusedWindow: AXUIElement?
    private var lastFocusValidation: TimeInterval = 0
    private var invalidated = false

    /// YouTube's TV page expects a TV user agent; Brave should use its normal desktop page.
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

    func open(_ url: URL) async throws {
        let destination = try Self.streamingURL(url)
        guard !invalidated else { throw CancellationError() }
        if windowID != nil { throw SessionError.noWindow }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.brave.Browser") else {
            throw SessionError.unavailable
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        guard !invalidated else { throw CancellationError() }
        let token = "Mac TV \(UUID().uuidString)"
        application = app
        ownershipToken = token
        do {
            let result = try runScript("create", value: destination.absoluteString)
            guard let id = result.stringValue, !id.isEmpty else { throw SessionError.noWindow }
            windowID = id
        } catch {
            application = nil
            ownershipToken = nil
            throw error
        }
    }

    /// Reuse the owned window, retaining its full-screen state and browser history.
    func navigate(to url: URL) throws {
        let destination = try Self.streamingURL(url)
        _ = try runScript("navigate", value: destination.absoluteString)
        validatedFocusedWindow = nil
        cachedBounds = nil
        pointer = nil
    }

    func fit(to screen: NSScreen) throws {
        let area = screen.visibleFrame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? area.maxY
        let bounds = NSRect(x: area.minX, y: primaryHeight - area.maxY, width: area.width, height: area.height)
        _ = try runScript("position", bounds: bounds)
        cachedBounds = nil
        pointer = nil
    }

    func activate() throws {
        validatedFocusedWindow = nil
        lastFocusValidation = 0
        _ = try runScript("activate")
        if let app = application, app.isActive, let token = ownershipToken,
           let focused = focusedWindow(of: app), windowTitle(focused)?.contains(token) == true {
            validatedFocusedWindow = focused
            lastFocusValidation = ProcessInfo.processInfo.systemUptime
        }
    }

    private func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        var value: CFTypeRef?
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func windowTitle(_ window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func activateForPointer(_ app: NSRunningApplication) throws {
        let age = ProcessInfo.processInfo.systemUptime - lastFocusValidation
        if age >= 0, age < 0.25, app.isActive, let owned = validatedFocusedWindow,
           let focused = focusedWindow(of: app), CFEqual(owned, focused) { return }
        try activate()
    }

    func close() throws {
        invalidated = true
        validatedFocusedWindow = nil
        lastFocusValidation = 0
        guard windowID != nil else { return }
        _ = try runScript("close")
        application = nil
        windowID = nil
        ownershipToken = nil
        cachedBounds = nil
        pointer = nil
    }

    /// Returns false for commands managed by Mac TV rather than Brave.
    @discardableResult
    func handle(_ command: RemoteCommand) throws -> Bool {
        guard let app = application, !app.isTerminated, windowID != nil else { throw SessionError.noWindow }
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
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { throw SessionError.eventCreation }
                event.postToPid(app.processIdentifier)
            }
            return true
        case .scroll(let dy):
            guard dy.isFinite else { return true }
            try activate()
            let bounds = try windowBounds(force: true)
            let p = pointer.flatMap { bounds.contains($0) ? $0 : nil } ?? CGPoint(x: bounds.midX, y: bounds.midY)
            let amount = Int32(max(-1000, min(1000, -dy)))
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0) else { throw SessionError.eventCreation }
            event.location = p
            event.postToPid(app.processIdentifier)
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
        let result = try runScript("bounds")
        guard result.numberOfItems == 4,
              let l = result.atIndex(1), let t = result.atIndex(2),
              let r = result.atIndex(3), let b = result.atIndex(4) else { throw SessionError.noWindow }
        let bounds = CGRect(x: Int(l.int32Value), y: Int(t.int32Value),
                            width: Int(r.int32Value - l.int32Value), height: Int(b.int32Value - t.int32Value))
        guard bounds.width > 2, bounds.height > 2 else { throw SessionError.noWindow }
        cachedBounds = bounds
        lastBoundsRead = Date()
        return bounds
    }

    // Values are AppleEvent descriptors, never interpolated into AppleScript source. The target
    // is Brave, guarded by the original process still running and a random window ownership name.
    static let scriptSource = """
        on perform_action(operation, windowID, marker, valueText)
          using terms from application "Brave Browser"
            tell application id "com.brave.Browser"
              if operation is "create" then
                set w to make new window
                try
                  set given name of w to marker
                  set URL of active tab of w to valueText
                  set index of w to 1
                  activate
                  return id of w
                on error messageText number errorNumber
                  try
                    close w
                  end try
                  error messageText number errorNumber
                end try
              end if
              set matches to every window whose id is windowID and given name is marker
              if (count of matches) is not 1 then error "Mac TV's Brave window no longer exists." number -1728
              set w to item 1 of matches
              if operation is "close" then
                close w
              else if operation is "activate" then
                set minimized of w to false
                set index of w to 1
                activate
              else if operation is "navigate" then
                set URL of active tab of w to valueText
                set minimized of w to false
                set index of w to 1
                activate
              else if operation is "position" then
                set bounds of w to valueText
              else if operation is "bounds" then
                return bounds of w
              end if
            end tell
          end using terms from
        end perform_action
        """
    static func compileScript() throws -> NSAppleScript {
        guard let script = NSAppleScript(source: scriptSource) else { throw SessionError.eventCreation }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else { throw scriptError(error) }
        return script
    }

    private static func scriptError(_ error: NSDictionary?) -> SessionError {
        if (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -1743 {
            return .automationDenied
        }
        if (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -1728 {
            return .noWindow
        }
        if (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -1712 {
            return .script("Brave did not respond in time. Check that it is running and try again.")
        }
        return .script(error?[NSAppleScript.errorMessage] as? String ?? "Apple Events permission or a browser error")
    }

    private func runScript(_ action: String, value: String = "", bounds: NSRect? = nil) throws -> NSAppleEventDescriptor {
        guard let app = application, !app.isTerminated, let token = ownershipToken else { throw SessionError.unavailable }
        let script: NSAppleScript
        if let cached = compiledScript { script = cached }
        else { script = try Self.compileScript(); compiledScript = script }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "perform_action"), forKeyword: AEKeyword(keyASSubroutineName))
        let args = NSAppleEventDescriptor.list()
        args.insert(NSAppleEventDescriptor(string: action), at: 1)
        args.insert(NSAppleEventDescriptor(string: windowID ?? ""), at: 2)
        args.insert(NSAppleEventDescriptor(string: token), at: 3)
        if let bounds {
            let rect = NSAppleEventDescriptor.list()
            for (index, value) in [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].enumerated() {
                rect.insert(NSAppleEventDescriptor(int32: Int32(clamping: Int(value))), at: index + 1)
            }
            args.insert(rect, at: 4)
        } else { args.insert(NSAppleEventDescriptor(string: value), at: 4) }
        event.setParam(args, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            if CommandLine.arguments.contains("--selftest-brave") { print("Brave AppleEvent error: \(error)") }
            throw Self.scriptError(error)
        }
        return result
    }
}
