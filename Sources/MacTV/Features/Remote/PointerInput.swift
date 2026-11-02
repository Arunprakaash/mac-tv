import AppKit

// The phone's touchpad as a pointer in Mac TV's window, and remote presses passed on as keys to a
// Mac app or Steam game Mac TV opened.
extension TVController {
    func movePointer(dx: Double, dy: Double) {
        guard let window, let bounds = window.contentView?.bounds else { return }
        var point = pointer ?? CGPoint(x: bounds.midX, y: bounds.midY)
        point.x = min(max(point.x + dx, 0), bounds.width - 1)
        point.y = min(max(point.y - dy, 0), bounds.height - 1)
        pointer = point

        let onScreen = window.convertPoint(toScreen: point)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.x, y: primaryHeight - onScreen.y))
        NSCursor.setHiddenUntilMouseMoves(false)
        postMouse(.mouseMoved, at: point)
    }

    func clickPointer() {
        guard let window, let bounds = window.contentView?.bounds else { return }
        let point = pointer ?? CGPoint(x: bounds.midX, y: bounds.midY)
        postMouse(.leftMouseDown, at: point)
        postMouse(.leftMouseUp, at: point)
    }

    private func postMouse(_ type: NSEvent.EventType, at point: CGPoint) {
        guard let window, let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
            pressure: type == .leftMouseDown ? 1 : 0)
        else { return }
        window.sendEvent(event)
    }

    // MARK: Keys for Mac apps and Steam games

    func forwardToFrontApp(_ command: RemoteCommand) {
        let code: CGKeyCode
        switch command {
        case .move(.left): code = 123
        case .move(.right): code = 124
        case .move(.down): code = 125
        case .move(.up): code = 126
        case .select: code = 36
        case .back: code = 53
        case .playPause: code = 49
        case .deleteBackward: code = 51
        case .text(let text):
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            for character in text {
                var units = Array(String(character).utf16)
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                    event.postToPid(pid)
                }
            }
            return
        default: return
        }
        SystemControl.postKeyToFrontApp(code)
    }
}
