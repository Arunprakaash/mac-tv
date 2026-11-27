import SwiftUI

// MARK: - Dialog contract
//
// Every focus-navigable sheet / modal / overlay ends with an `InputHintsBar`.
// No plain-text legends ("Esc or Back…", "↑ ↓ Choose…"). No header "Done" —
// Back/Close is the dismiss affordance for every input kind (glyphs adapt).
//
// Standard sets (`HintSet`) keep verbs stable across screens:
//   list        Choose · Select · Close
//   listAdjust  Choose · Change · Select · Close
//   form        Choose · Select · Close   (fields / tabs)
//   arrange     Choose app · Choose action · Apply · Close
//               (Arrange sheet swaps Apply → Hold to remove when trash is focused)
//   chooser     Select · Close           (2–3 buttons)
//   pick        Choose · Select          (non-dismissible: Profiles, Setup)
//   info        Close
//
// Glyphs follow `tv.lastInputKind` (last device that issued a command):
//   keyboard → keycaps   remote → phone-remote OK disc / chevron Back / chevrons
//   controller → SF face buttons from ControllerInfo
//
// Mouse / trackpad / pointer map to keyboard glyphs. Do not invent a mouse-only mode.
// Sheets over home prefer `tvPanel` radius 44; full-bleed (Settings, Setup, Profiles)
// still show the same footer bar.

/// Which device last drove navigation — legends show only this device's glyphs.
enum InputKind: Equatable {
    case remote, keyboard, controller

    init(_ source: Feedback.Source) {
        switch source {
        case .remote: self = .remote
        case .controller: self = .controller
        case .keyboard, .trackpad, .pointer: self = .keyboard
        }
    }
}

/// A footer legend entry: stable verb, device-specific glyph.
enum HintAction: Equatable {
    /// All four directions, for grids.
    case move(String)
    case moveVertical(String)
    case moveHorizontal(String)
    case select(String)
    case back(String)
    /// Always an SF Symbol badge (Menu / Home on the controller strip).
    case symbol(String, String)
    /// The Delete key: ⌫ on a keyboard, the phone remote's delete key.
    case delete(String)

    var label: String {
        switch self {
        case .move(let s), .moveVertical(let s), .moveHorizontal(let s), .select(let s), .back(let s), .symbol(_, let s), .delete(let s): s
        }
    }
}

/// Shared footer action sets — prefer these over ad-hoc action arrays.
enum HintSet: Equatable {
    case list
    case listAdjust
    case form
    case arrange
    case chooser
    /// Non-dismissible pickers (Profiles, Setup steps).
    case pick
    case info
    case custom([HintAction])

    var actions: [HintAction] {
        switch self {
        case .list:
            [.moveVertical("Choose"), .select("Select"), .back("Close")]
        case .listAdjust:
            [.moveVertical("Choose"), .moveHorizontal("Change"), .select("Select"), .back("Close")]
        case .form:
            [.moveVertical("Choose"), .select("Select"), .back("Close")]
        case .arrange:
            [.moveVertical("Choose app"), .moveHorizontal("Choose action"), .select("Apply"), .back("Close")]
        case .chooser:
            [.select("Select"), .back("Close")]
        case .pick:
            [.moveHorizontal("Choose"), .select("Select")]
        case .info:
            [.back("Close")]
        case .custom(let actions):
            actions
        }
    }
}

/// Footer legend: badge + verb, glyphs follow `tv.lastInputKind`.
struct InputHintsBar: View {
    @ObservedObject var tv: TVController
    var set: HintSet = .info
    var note: String? = nil
    /// When set, ignore last-active (rare; prefer following `lastInputKind`).
    var forceKind: InputKind? = nil

    init(tv: TVController, set: HintSet, note: String? = nil, forceKind: InputKind? = nil) {
        self.tv = tv
        self.set = set
        self.note = note
        self.forceKind = forceKind
    }

    init(tv: TVController, actions: [HintAction], note: String? = nil, forceKind: InputKind? = nil) {
        self.tv = tv
        self.set = .custom(actions)
        self.note = note
        self.forceKind = forceKind
    }

    var body: some View {
        let kind = forceKind ?? tv.lastInputKind
        HStack(spacing: 18) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                if case .back = action {
                    // The way out with a mouse or trackpad, now that sheets have no Done button.
                    InputHint(action: action, kind: kind, controller: tv.controller)
                        .contentShape(Rectangle())
                        .onTapGesture { tv.handle(.back, from: .pointer) }
                } else {
                    InputHint(action: action, kind: kind, controller: tv.controller)
                }
            }
            if let note {
                Text("· \(note)")
            }
        }
        .font(.tv(.caption2))
        .foregroundStyle(.white.opacity(0.65))
    }

    /// Typing fields: controller → Select becomes "Open keyboard"; keyboard/mouse → drop Select
    /// (just start typing). Remote keeps its normal Select verb.
    private var actions: [HintAction] {
        let list = set.actions
        let kind = forceKind ?? tv.lastInputKind
        if tv.isTypingFieldFocused, kind == .keyboard {
            return list.filter { if case .select = $0 { false } else { true } }
        }
        guard kind == .controller, tv.showsOpenKeyboardOnSelect else { return list }
        var replaced = false
        let mapped: [HintAction] = list.map { action in
            guard case .select = action else { return action }
            replaced = true
            return .select("Open keyboard")
        }
        return replaced ? mapped : mapped + [.select("Open keyboard")]
    }
}

struct InputHint: View {
    let action: HintAction
    let kind: InputKind
    var controller: ControllerInfo?

    var body: some View {
        HStack(spacing: 7) {
            badge
            Text(action.label)
        }
    }

    @ViewBuilder private var badge: some View {
        switch action {
        case .move:
            switch kind {
            case .remote: HStack(spacing: 4) { remoteChevrons(vertical: true); remoteChevrons(vertical: false) }
            case .keyboard: framedText("↑↓←→")
            case .controller: symbolBadge("dpad.fill")
            }
        case .moveVertical:
            switch kind {
            case .remote: remoteChevrons(vertical: true)
            case .keyboard: framedText("↑↓")
            case .controller: symbolBadge("dpad.fill")
            }
        case .moveHorizontal:
            switch kind {
            case .remote: remoteChevrons(vertical: false)
            case .keyboard: framedText("←→")
            case .controller: symbolBadge("dpad.fill")
            }
        case .select:
            faceBadge(select: true)
        case .back:
            faceBadge(select: false)
        case .symbol(let name, _):
            symbolBadge(name)
        case .delete:
            if kind == .keyboard { framedText("⌫") } else { symbolBadge("delete.left") }
        }
    }

    @ViewBuilder private func faceBadge(select: Bool) -> some View {
        switch kind {
        case .keyboard:
            framedText(select ? "↵" : "Esc")
        case .remote:
            // Phone remote: centre OK disc, or the circular Back key with a left chevron.
            if select {
                remoteCircle {
                    Text("OK").font(.system(size: 13, weight: .bold, design: .rounded))
                }
            } else {
                remoteCircle {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        case .controller:
            symbolBadge(select ? (controller?.selectSymbol ?? "a.circle") : (controller?.backSymbol ?? "b.circle"))
        }
    }

    private func symbolBadge(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .medium))
            .symbolRenderingMode(.hierarchical)
    }

    private func framedText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.45), lineWidth: 1))
    }

    /// Mini Clickpad chevrons, same strokes as the phone remote ring.
    private func remoteChevrons(vertical: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: vertical ? "chevron.up" : "chevron.left")
            Image(systemName: vertical ? "chevron.down" : "chevron.right")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 1))
    }

    /// Circular glass key matching `.key` / `.ok` on the phone remote.
    private func remoteCircle<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: 28, height: 28)
            .background(.white.opacity(0.1), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}
