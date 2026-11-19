import AppKit
import Testing
@testable import MacTV

struct InputKindTests {
    @Test func mapsFeedbackSources() {
        #expect(InputKind(.keyboard) == .keyboard)
        #expect(InputKind(.trackpad) == .keyboard)
        #expect(InputKind(.pointer) == .keyboard)
        #expect(InputKind(.remote) == .remote)
        #expect(InputKind(.controller) == .controller)
    }

    @Test func hintSetsKeepStableVerbs() {
        #expect(HintSet.list.actions.map(\.label) == ["Choose", "Select", "Close"])
        #expect(HintSet.listAdjust.actions.map(\.label) == ["Choose", "Change", "Select", "Close"])
        #expect(HintSet.arrange.actions.map(\.label) == ["Choose app", "Choose action", "Apply", "Close"])
        #expect(HintSet.info.actions.map(\.label) == ["Close"])
        #expect(HintSet.pick.actions.map(\.label) == ["Choose", "Select"])
    }
}

@MainActor
struct InputHintBehaviourTests {
    @Test func gridsGetOneMoveHint() {
        #expect(HintAction.move("Choose").label == "Choose")
    }

    @Test func rowsWhereOKDoesNothingHaveNoOKHint() {
        for row in [SettingsPanel.Row.pairingCode, .version, .source] { #expect(row.okVerb.isEmpty) }
        #expect(SettingsPanel.Row.autoSkip.okVerb == "Toggle")
        #expect(SettingsPanel.Row.audioOutput.okVerb == "Open")
    }

    /// Every command reports its input; only a change of input may redraw the screens watching it.
    @Test func sameInputDoesNotRepublish() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/hints-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        _ = NSApplication.shared
        // In Settings, arrows only move its focus.
        tv.settings = SettingsPanel()
        var kinds: [InputKind] = []
        let watch = tv.$lastInputKind.dropFirst().sink { kinds.append($0) }
        defer { watch.cancel() }
        tv.handle(.move(.down), from: .keyboard)
        tv.handle(.move(.down), from: .keyboard)
        tv.handle(.move(.up), from: .controller)
        tv.handle(.move(.up), from: .controller)
        #expect(kinds == [.controller])
    }
}
