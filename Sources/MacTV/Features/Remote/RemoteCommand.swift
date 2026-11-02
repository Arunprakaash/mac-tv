import Foundation

/// A press from any remote: the phone, the keyboard, a game controller or the mouse.
enum RemoteCommand {
    enum Direction: String { case up, down, left, right }

    case move(Direction), select, back, home
    case playPause, seek(forward: Bool)
    case volume(Int), mute
    case text(String), deleteBackward
    case pointer(dx: Double, dy: Double), click, scroll(dy: Double)
    case launch(String), openInBrowser
    case screenOff, screenOn, sleepMac
    case sleepTimer(minutes: Int)
    case controlCenter
    case nextControl, previousControl, activateBrowser, browserFullscreen, retryBrowser
    case setting(String, Bool)

    init?(json: [String: Any]) {
        guard let action = json["a"] as? String else { return nil }
        switch action {
        case "up", "down", "left", "right": self = .move(Direction(rawValue: action)!)
        case "ok": self = .select
        case "back": self = .back
        case "home": self = .home
        case "playpause": self = .playPause
        case "rewind": self = .seek(forward: false)
        case "forward": self = .seek(forward: true)
        case "volup": self = .volume(6)
        case "voldown": self = .volume(-6)
        case "mute": self = .mute
        case "text":
            guard let text = json["t"] as? String, !text.isEmpty else { return nil }
            self = .text(String(text.prefix(500)))
        case "backspace": self = .deleteBackward
        case "pointer": self = .pointer(dx: json["dx"] as? Double ?? 0, dy: json["dy"] as? Double ?? 0)
        case "click": self = .click
        case "scroll": self = .scroll(dy: json["dy"] as? Double ?? 0)
        case "launch":
            guard let id = json["id"] as? String else { return nil }
            self = .launch(id)
        case "browser": self = .openInBrowser
        case "screenoff": self = .screenOff
        case "screenon": self = .screenOn
        case "sleep": self = .sleepMac
        case "sleeptimer": self = .sleepTimer(minutes: json["m"] as? Int ?? 0)
        case "controlcenter": self = .controlCenter
        case "nextcontrol": self = .nextControl
        case "previouscontrol": self = .previousControl
        case "activatebrowser": self = .activateBrowser
        case "browserfullscreen": self = .browserFullscreen
        case "retrybrowser": self = .retryBrowser
        case "setting":
            guard let key = json["k"] as? String, let value = json["v"] as? Bool else { return nil }
            self = .setting(key, value)
        default: return nil
        }
    }
}
