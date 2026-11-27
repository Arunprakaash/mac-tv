import SwiftUI

/// Notifies Mac TV when a real text field gains or loses focus in the built-in web player.
enum TypingProbe {
    static let messageName = "macTVTyping"
    static let script = #"""
    (() => {
      if (window.__macTVTyping) return;
      window.__macTVTyping = true;
      let last = null;
      const check = () => {
        const a = document.activeElement;
        // Text-like fields only: not checkboxes, buttons, sliders or drop-downs.
        const textInput = a && a.tagName === 'INPUT'
          && /^(|text|search|email|url|password|tel|number)$/i.test(a.getAttribute('type') || '');
        const typing = !!a && (a.isContentEditable || a.tagName === 'TEXTAREA' || !!textInput);
        if (typing === last) return;
        last = typing;
        try { window.webkit.messageHandlers.macTVTyping.postMessage(typing); } catch (_) {}
      };
      document.addEventListener('focusin', check, true);
      document.addEventListener('focusout', () => setTimeout(check, 0), true);
    })();
    """#
}

/// Controller-driven on-screen keyboard for streaming apps and typing sheets (Add App, profiles,
/// network shares): a tvOS-style glass overlay that never steals first responder from the web
/// player. Face buttons while open: A type, B close, X delete, Y space; L2/⇧ for capitals and
/// URL punctuation; L1/R1 jump columns. Sheets open with A; Y opens when a field is focused;
/// Done submits.
struct OnScreenKeyboardState: Equatable {
    enum Layout: String, CaseIterable {
        case qwerty, qwertz, azerty, spanish, nordic

        var title: String {
            switch self {
            case .qwerty: "QWERTY"
            case .qwertz: "QWERTZ"
            case .azerty: "AZERTY"
            case .spanish: "ES"
            case .nordic: "Nordic"
            }
        }

        static func from(preference: String?) -> Layout {
            Layout(rawValue: preference ?? "") ?? .qwerty
        }

        /// Default from the Mac's language when the user hasn't picked one yet.
        static func from(languageCode: String?) -> Layout {
            switch languageCode {
            case "de": .qwertz
            case "fr": .azerty
            case "es": .spanish
            case "sv", "nb", "nn", "da", "fi", "is": .nordic
            default: .qwerty
            }
        }
    }

    var isOpen = false
    var row = 0
    var column = 0
    /// Column to restore when leaving a wide Space/Done key vertically.
    var preferredColumn = 0
    var layout: Layout = .qwerty
    /// Sticky Shift from the Shift key; cleared after a character insert.
    var stickyShift = false
    /// Held from L2 while open.
    var holdShift = false
    /// Held from X while open (Delete key lights like Shift).
    var holdDelete = false

    var shift: Bool { stickyShift || holdShift }

    /// Aligned grid (macpad / ConType): even cells for D-pad navigation.
    var rows: [[Key]] { Self.grid(layout) }
    var columnCount: Int { rows[0].count }
    var rowCount: Int { rows.count }
    var focusedKey: Key { rows[row][column] }

    /// Shared 11-column chrome: Delete top-right; locale extras on the right; `@ / -` after
    /// the last letter; `, .` then Done. Letter order + right extras vary by layout.
    static func grid(_ layout: Layout) -> [[Key]] {
        let extras = localeExtras(layout)
        let block: [[Key]] = switch layout {
        case .qwerty, .spanish, .nordic:
            [
                chars("qwertyuiop") + [extras.right[0]],
                chars("asdfghjkl") + [extras.mid, extras.right[1]],
                chars("zxcvbnm") + [.char("@"), .char("/"), .char("-"), extras.right[2]],
            ]
        case .qwertz:
            [
                chars("qwertzuiop") + [extras.right[0]],
                chars("asdfghjkl") + [extras.mid, extras.right[1]],
                chars("yxcvbnm") + [.char("@"), .char("/"), .char("-"), extras.right[2]],
            ]
        case .azerty:
            [
                chars("azertyuiop") + [extras.right[0]],
                chars("qsdfghjklm") + [extras.mid], // m sits on the home row in AZERTY
                chars("wxcvbn") + [.char("@"), .char("/"), .char("-"), extras.right[1], extras.right[2]],
            ]
        }
        // AZERTY home row is already 11 wide (… m à); pad isn't needed.
        return [
            chars("1234567890") + [.delete],
        ] + block + [
            [.shift, .space, .space, .space, .space, .space,
             .char(","), .char("."), .done, .done, .done],
        ]
    }

    private static func chars(_ s: String) -> [Key] { s.map { .char(String($0)) } }

    /// Mid key (beside `l`) + three right-column keys (under Delete), per layout.
    private static func localeExtras(_ layout: Layout) -> (mid: Key, right: [Key]) {
        switch layout {
        case .qwerty: (.char(":"), [.char("'"), .char("_"), .char("?")])
        case .qwertz: (.char("ö"), [.char("ü"), .char("ä"), .char("ß")])
        case .azerty: (.char("à"), [.char("é"), .char("è"), .char("ç")])
        case .spanish: (.char("ñ"), [.char("'"), .char("¿"), .char("¡")])
        case .nordic: (.char("å"), [.char("ö"), .char("ä"), .char("ø")])
        }
    }

    enum Key: Equatable {
        case char(String)
        case shift, space, delete, done

        /// Per-layout shift glyphs. Each output appears once (never also on the base row).
        static func shiftAlternates(for layout: Layout) -> [String: String] {
            let digits: [String: String] = [
                "1": "!", "2": "*", "3": "+", "4": "$", "5": "%",
                "6": "~", "7": "|", "8": "(", "9": ")", "0": "=",
            ]
            switch layout {
            case .qwerty:
                // Base has ' : _ ? @ / - , .
                return digits.merging(["'": "\"", "@": "#", ",": ";"]) { _, new in new }
            case .spanish:
                // Base has ' ¿ ¡ ñ @ / - , . — URL leftovers on shift.
                return digits.merging([
                    "'": "\"", "-": "_", ".": ":", "/": "?", "@": "#", ",": ";",
                ]) { _, new in new }
            case .qwertz, .azerty, .nordic:
                // Accent letters on base; URL punctuation via shift. ß → & (never SS).
                var map = digits.merging([
                    "-": "_", ".": ":", "/": "?", ",": ";", "@": "#",
                ]) { _, new in new }
                if layout == .qwertz { map["ß"] = "&" }
                if layout == .nordic { map["ø"] = "æ" } // æ only on shift, not a second base key
                return map
            }
        }

        func label(shift: Bool, layout: Layout) -> String {
            switch self {
            case .char(let c):
                if shift, let alt = Self.shiftAlternates(for: layout)[c] { return alt }
                if shift, c.first?.isLetter == true { return c.uppercased() }
                return c
            case .shift: return "⇧"
            case .space: return "space"
            case .delete: return "⌫"
            case .done: return "Done"
            }
        }
    }

    mutating func open(layout: Layout) {
        self.layout = layout
        isOpen = true
        row = 1
        column = 0
        preferredColumn = 0
        stickyShift = false
        holdShift = false
        holdDelete = false
    }

    mutating func close() {
        isOpen = false
        stickyShift = false
        holdShift = false
        holdDelete = false
    }

    mutating func move(_ direction: RemoteCommand.Direction) {
        switch direction {
        case .left, .right:
            // Move by visual groups so Space/Done aren't a one-way trap (right used to snap back).
            let groups = groups(in: row)
            let index = groups.firstIndex { column >= $0.start && column < $0.start + $0.span } ?? 0
            let next = direction == .right
                ? (index + 1 < groups.count ? index + 1 : 0)
                : (index > 0 ? index - 1 : groups.count - 1)
            column = groups[next].start
            rememberPreferredColumn()
        case .up, .down:
            let leaving = focusedKey
            let span = wideSpan(for: leaving)
            if direction == .up {
                row = row > 0 ? row - 1 : rowCount - 1
            } else {
                row = row < rowCount - 1 ? row + 1 : 0
            }
            var col = min(preferredColumn, columnCount - 1)
            // Stale preferred outside Space/Done → nearest column still under that key.
            if let span {
                col = Self.nearestColumn(col, start: span.start, span: span.span, columnCount: columnCount)
            }
            column = col
            snapToGroupStart()
            // Adopt the landed column (e.g. Done clamped 7→8) so the next vertical step keeps it.
            rememberPreferredColumn()
        }
    }

    mutating func jumpColumns(_ delta: Int) {
        column = max(0, min(columnCount - 1, column + delta))
        snapToGroupStart()
        rememberPreferredColumn()
    }

    enum Action: Equatable {
        case insert(String)
        case delete
        case dismiss
        case none
    }

    mutating func activateFocused() -> Action { activate(focusedKey) }

    mutating func activate(_ key: Key) -> Action {
        switch key {
        case .shift:
            stickyShift.toggle()
            return .none
        case .space:
            return .insert(" ")
        case .delete:
            return .delete
        case .done:
            // Don't close here — the controller wraps close in Motion.appear so the overlay can exit.
            return .dismiss
        case .char(let raw):
            let text: String
            if shift, let alt = Key.shiftAlternates(for: layout)[raw] {
                text = alt
            } else if shift, raw.first?.isLetter == true {
                text = raw.uppercased()
            } else {
                text = raw
            }
            if stickyShift { stickyShift = false }
            return .insert(text)
        }
    }

    mutating func snapToGroupStart() {
        let keys = rows[row]
        let key = keys[column]
        guard key == .space || key == .done else { return }
        while column > 0, keys[column - 1] == key { column -= 1 }
    }

    /// Wide keys pin `column` to their start; keep the letter-row column for the next vertical move.
    mutating func rememberPreferredColumn() {
        let key = focusedKey
        if key == .space || key == .done { return }
        preferredColumn = column
    }

    func wideSpan(for key: Key) -> (start: Int, span: Int)? {
        guard key == .space || key == .done else { return nil }
        return groups(in: row).first { $0.key == key }.map { ($0.start, $0.span) }
    }

    /// Circular nearest column inside `start ..< start+span` (Shift↔Done wrap on a 10-wide row).
    static func nearestColumn(_ preferred: Int, start: Int, span: Int, columnCount: Int) -> Int {
        let end = start + span - 1
        if preferred >= start, preferred <= end { return preferred }
        func dist(_ a: Int, _ b: Int) -> Int {
            let d = abs(a - b)
            return min(d, columnCount - d)
        }
        return (start...end).min(by: { dist(preferred, $0) < dist(preferred, $1) }) ?? start
    }

    /// Starts of visual groups in a row (for drawing wide space/done keys).
    func groups(in row: Int) -> [(start: Int, span: Int, key: Key)] {
        let keys = rows[row]
        var groups: [(Int, Int, Key)] = []
        var index = 0
        while index < keys.count {
            let key = keys[index]
            var span = 1
            if key == .space || key == .done {
                while index + span < keys.count, keys[index + span] == key { span += 1 }
            }
            groups.append((index, span, key))
            index += span
        }
        return groups
    }
}

/// Bottom of the focused typing field in `OnScreenKeyboardView.canvasSpace` (nil when unfocused).
enum FocusedTypingFieldBottomKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = max(value ?? next, next) }
    }
}

/// Lifts only the sheet panel when the focused field would sit under the docked keyboard.
/// Backdrop stays put. Lift is derived from the field's rest position so it does not oscillate.
struct AvoidsOnScreenKeyboard: ViewModifier {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas
    @State private var reportedBottom: CGFloat?
    @State private var lift: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(y: -lift)
            .onPreferenceChange(FocusedTypingFieldBottomKey.self) { bottom in
                reportedBottom = bottom
                recalculate()
            }
            .onChange(of: tv.onScreenKeyboard.isOpen) { _, _ in recalculate() }
            .onChange(of: canvas.height) { _, _ in recalculate() }
            .animation(Motion.appear, value: lift)
    }

    private func recalculate() {
        let next: CGFloat
        if tv.onScreenKeyboard.isOpen, let visualBottom = reportedBottom {
            // `offset` is visual only; undo the current lift to get the laid-out rest position.
            let restBottom = visualBottom + lift
            next = max(0, restBottom + 24 - (canvas.height - OnScreenKeyboardView.dockedHeight))
        } else {
            next = 0
        }
        if next != lift { lift = next }
    }
}

extension View {
    /// Move this panel (not the dimmed backdrop) up just enough to keep the focused field readable.
    func avoidsOnScreenKeyboard(tv: TVController) -> some View {
        modifier(AvoidsOnScreenKeyboard(tv: tv))
    }

    /// Report the bottom edge while focused so `avoidsOnScreenKeyboard` can measure overlap.
    func reportsTypingFieldBottom(focused: Bool) -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: FocusedTypingFieldBottomKey.self,
                    value: focused ? geo.frame(in: .named(OnScreenKeyboardView.canvasSpace)).maxY : nil
                )
            }
        }
    }
}

/// tvOS keyboard: one focus platter that glides between keys like Settings.
struct OnScreenKeyboardView: View {
    @ObservedObject var tv: TVController
    let state: OnScreenKeyboardState

    static let canvasSpace = "tvCanvas"
    /// Canvas points occupied by the docked keyboard (panel + bottom inset).
    static let dockedHeight: CGFloat = 560

    @Namespace private var focusSpace

    private let spacing: CGFloat = 12
    private let keyHeight: CGFloat = 72
    private let corner: CGFloat = 20

    var body: some View {
        VStack(spacing: 22) {
            GlassGroup(spacing: 0) {
                GeometryReader { geo in
                    let unit = (geo.size.width - spacing * CGFloat(state.columnCount - 1)) / CGFloat(state.columnCount)
                    VStack(spacing: spacing) {
                        ForEach(0..<state.rowCount, id: \.self) { r in
                            HStack(spacing: spacing) {
                                ForEach(Array(state.groups(in: r).enumerated()), id: \.offset) { _, group in
                                    keyCap(group.key, row: r, start: group.start, span: group.span, unit: unit)
                                }
                            }
                        }
                    }
                }
                .frame(height: CGFloat(state.rowCount) * keyHeight + CGFloat(state.rowCount - 1) * spacing)
            }

            InputHintsBar(tv: tv, actions: keyboardHints, forceKind: .controller)
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(width: 1_140)
        .tvGlass(in: RoundedRectangle(cornerRadius: 40, style: .continuous), tint: .black.opacity(0.28))
        .shadow(color: .black.opacity(0.55), radius: 48, y: 22)
        .animation(Motion.focus, value: state.row)
        .animation(Motion.focus, value: state.column)
        .animation(Motion.focus, value: state.shift)
        .animation(Motion.focus, value: state.holdDelete)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Type → Space → Delete → Shift → Close: compose, then fix, then leave.
    private var keyboardHints: [HintAction] {
        let c = tv.controller
        return [
            .select("Type"),
            .symbol(c?.ySymbol ?? "y.circle", "Space"),
            .symbol(c?.xSymbol ?? "x.circle", "Delete"),
            .symbol(c?.leftTriggerSymbol ?? "l2.button.angledbottom.horizontal.left", "Shift"),
            .back("Close"),
        ]
    }

    private func keyCap(_ key: OnScreenKeyboardState.Key, row: Int, start: Int, span: Int, unit: CGFloat) -> some View {
        let focused = isFocused(row: row, start: start, key: key)
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let width = unit * CGFloat(span) + spacing * CGFloat(span - 1)
        let special = key == .space || key == .done || key == .shift || key == .delete
        return Text(key.label(shift: state.shift, layout: state.layout))
            .font(.tv(special ? .caption1 : .body, emphasized: focused || key == .done))
            .contentTransition(.interpolate)
            .foregroundStyle(focused ? .black : .white)
            .frame(width: width, height: keyHeight)
            .background {
                if focused {
                    // One platter that glides from key to key as focus moves, like Settings.
                    shape.fill(.white)
                        .matchedGeometryEffect(id: "focus", in: focusSpace)
                } else {
                    shape.fill(.white.opacity(0.14))
                }
            }
            .overlay {
                let lit = (key == .shift && state.shift) || (key == .delete && state.holdDelete)
                if lit, !focused {
                    shape.strokeBorder(.white.opacity(0.55), lineWidth: 2)
                }
            }
            .scaleEffect(focused ? 1.06 : 1)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: focused ? 20 : 0, y: focused ? 14 : 0)
            .zIndex(focused ? 1 : 0)
    }

    private func isFocused(row: Int, start: Int, key: OnScreenKeyboardState.Key) -> Bool {
        guard state.row == row else { return false }
        if key == .space || key == .done {
            return state.rows[state.row][state.column] == key
        }
        return state.column == start
    }
}
