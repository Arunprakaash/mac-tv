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
