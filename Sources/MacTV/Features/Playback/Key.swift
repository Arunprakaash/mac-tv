import AppKit

/// A key press delivered to the web view as if typed on the Mac's keyboard.
struct Key {
    let code: UInt16
    let chars: String
    var flags: NSEvent.ModifierFlags = []

    private static func arrow(_ code: UInt16, _ scalar: Int) -> Key {
        Key(code: code, chars: String(UnicodeScalar(UInt32(scalar))!), flags: [.numericPad, .function])
    }

    static let left = arrow(123, NSLeftArrowFunctionKey)
    static let right = arrow(124, NSRightArrowFunctionKey)
    static let down = arrow(125, NSDownArrowFunctionKey)
    static let up = arrow(126, NSUpArrowFunctionKey)
    static let enter = Key(code: 36, chars: "\r")
    static let escape = Key(code: 53, chars: "\u{1b}")
    static let space = Key(code: 49, chars: " ")
    static let delete = Key(code: 51, chars: "\u{7f}")

    static func direction(_ d: RemoteCommand.Direction) -> Key {
        switch d {
        case .up: up
        case .down: down
        case .left: left
        case .right: right
        }
    }
}
