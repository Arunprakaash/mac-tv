import Testing
@testable import MacTV

@Suite struct OnScreenKeyboardTests {
    @Test func moveWrapsAndSnapsWideKeys() {
        var keyboard = OnScreenKeyboardState()
        keyboard.open(layout: .qwerty)
        #expect(keyboard.row == 1 && keyboard.column == 0)
        #expect(keyboard.columnCount == 11)

        keyboard.move(.left)
        #expect(keyboard.column == keyboard.columnCount - 1)

        keyboard.row = 4
        keyboard.column = 4
        keyboard.snapToGroupStart()
        #expect(keyboard.focusedKey == .space)
        #expect(keyboard.column == 1)

        keyboard.column = 9
        keyboard.snapToGroupStart()
        #expect(keyboard.focusedKey == .done)
        #expect(keyboard.column == 8)
    }

    @Test func moveRightLeavesSpaceAndDone() {
        var keyboard = OnScreenKeyboardState()
        keyboard.open(layout: .qwerty)
        keyboard.row = 4
        keyboard.column = 1
        keyboard.snapToGroupStart()
        #expect(keyboard.focusedKey == .space)

        keyboard.move(.right)
        #expect(keyboard.focusedKey == .char(","))

        keyboard.move(.right)
        #expect(keyboard.focusedKey == .char("."))

        keyboard.move(.right)
        #expect(keyboard.focusedKey == .done)

        keyboard.move(.right)
        #expect(keyboard.focusedKey == .shift)
    }

    @Test func verticalWrapKeepsPreferredColumn() {
        var keyboard = OnScreenKeyboardState()
        keyboard.open(layout: .qwerty)
        // Letter row, column of "r" (index 3).
        keyboard.row = 1
        keyboard.column = 3
        keyboard.rememberPreferredColumn()
        #expect(keyboard.preferredColumn == 3)

        keyboard.move(.down)
        keyboard.move(.down)
        keyboard.move(.down)
        #expect(keyboard.row == 4)
        #expect(keyboard.focusedKey == .space)

        // Wrapping past Space used to land on "2" (space's start column). Keep "4".
        keyboard.move(.down)
        #expect(keyboard.row == 0)
        #expect(keyboard.column == 3)
        #expect(keyboard.focusedKey == .char("4"))
    }

    @Test func verticalWrapFromDoneKeepsPreferredColumn() {
        var keyboard = OnScreenKeyboardState()
        keyboard.open(layout: .qwerty)
        // Prefer column 8 (inside Done), land on Done, wrap keeps "9".
        keyboard.row = 1
        keyboard.column = 8
        keyboard.rememberPreferredColumn()
        keyboard.row = 4
        keyboard.column = 8
        keyboard.snapToGroupStart()
        #expect(keyboard.focusedKey == .done)
        #expect(keyboard.preferredColumn == 8)

        keyboard.move(.down)
        #expect(keyboard.row == 0)
        #expect(keyboard.column == 8)
        #expect(keyboard.focusedKey == .char("9"))
    }

    @Test func verticalWrapClampsPreferredIntoWideKey() {
        var keyboard = OnScreenKeyboardState()
        keyboard.open(layout: .qwerty)

        // On Space with preferred under Shift ("1") → nearest Space col → "2".
        keyboard.row = 4
        keyboard.column = 1
        keyboard.snapToGroupStart()
        keyboard.preferredColumn = 0
        keyboard.move(.down)
        #expect(keyboard.column == 1)
        #expect(keyboard.focusedKey == .char("2"))

        // On Space with preferred on "," → nearest Space edge → "6".
        keyboard.row = 4
        keyboard.column = 1
        keyboard.snapToGroupStart()
        keyboard.preferredColumn = 6
        keyboard.move(.down)
        #expect(keyboard.column == 5)
        #expect(keyboard.focusedKey == .char("6"))

        // On Done with preferred on "," → left edge of Done → "9".
        keyboard.row = 4
        keyboard.column = 8
        keyboard.snapToGroupStart()
        keyboard.preferredColumn = 6
        keyboard.move(.down)
        #expect(keyboard.column == 8)
        #expect(keyboard.focusedKey == .char("9"))
        #expect(keyboard.preferredColumn == 8)

        // On Done with preferred under Shift → wrap to Done's right edge → Delete.
        keyboard.row = 4
        keyboard.column = 8
        keyboard.snapToGroupStart()
        keyboard.preferredColumn = 0
        keyboard.move(.down)
        #expect(keyboard.column == 10)
        #expect(keyboard.focusedKey == .delete)
        #expect(keyboard.preferredColumn == 10)
    }

    @Test func clampedPreferredSticksOnNextVerticalMove() {
        var keyboard = OnScreenKeyboardState()
        keyboard.open(layout: .qwerty)
        // Came from col 7, on Done; wrap clamps to 8.
        keyboard.row = 4
        keyboard.column = 8
        keyboard.snapToGroupStart()
        keyboard.preferredColumn = 7
        keyboard.move(.down)
        #expect(keyboard.row == 0)
        #expect(keyboard.column == 8)
        #expect(keyboard.preferredColumn == 8)

        // Next down must keep 8 (used to fall back to stale preferred 7).
        keyboard.move(.down)
        #expect(keyboard.row == 1)
        #expect(keyboard.column == 8)
    }

    @Test func nearestColumnCircular() {
        #expect(OnScreenKeyboardState.nearestColumn(0, start: 1, span: 5, columnCount: 11) == 1)
        #expect(OnScreenKeyboardState.nearestColumn(6, start: 1, span: 5, columnCount: 11) == 5)
        #expect(OnScreenKeyboardState.nearestColumn(6, start: 8, span: 3, columnCount: 11) == 8)
        #expect(OnScreenKeyboardState.nearestColumn(0, start: 8, span: 3, columnCount: 11) == 10)
        #expect(OnScreenKeyboardState.nearestColumn(9, start: 8, span: 3, columnCount: 11) == 9)
    }

    @Test func jumpColumnsClamps() {
        var keyboard = OnScreenKeyboardState()
        keyboard.open(layout: .qwerty)
        keyboard.jumpColumns(5)
        #expect(keyboard.column == 5)
        keyboard.jumpColumns(20)
        #expect(keyboard.column == keyboard.columnCount - 1)
        keyboard.jumpColumns(-20)
        #expect(keyboard.column == 0)
    }

    @Test func shiftStickyClearsAfterLetter() {
        var keyboard = OnScreenKeyboardState()
        keyboard.open(layout: .qwerty)
        #expect(keyboard.activate(.shift) == .none)
        #expect(keyboard.stickyShift)
        #expect(keyboard.activate(.char("a")) == .insert("A"))
        #expect(!keyboard.stickyShift)
        #expect(keyboard.activate(.char("b")) == .insert("b"))
    }

    @Test func holdShiftOverridesStickyOff() {
        var keyboard = OnScreenKeyboardState()
        keyboard.open(layout: .qwerty)
        keyboard.holdShift = true
        #expect(keyboard.activate(.char("q")) == .insert("Q"))
        #expect(keyboard.holdShift)
    }

    @Test func faceButtonActions() {
        var keyboard = OnScreenKeyboardState()
        keyboard.open(layout: .qwerty)
        #expect(keyboard.activate(.space) == .insert(" "))
        #expect(keyboard.activate(.done) == .dismiss)
        #expect(keyboard.isOpen)
    }

    @Test func deleteKeyDeletes() {
        var keyboard = OnScreenKeyboardState()
        keyboard.open(layout: .qwerty)
        #expect(keyboard.activate(.delete) == .delete)
        #expect(keyboard.isOpen)
    }

    @Test func qwertzSwapsYAndZ() {
        var qwerty = OnScreenKeyboardState()
        qwerty.open(layout: .qwerty)
        #expect(qwerty.rows[1][5] == .char("y"))
        #expect(qwerty.rows[3][0] == .char("z"))

        var qwertz = OnScreenKeyboardState()
        qwertz.open(layout: .qwertz)
        #expect(qwertz.rows[1][5] == .char("z"))
        #expect(qwertz.rows[3][0] == .char("y"))
        #expect(qwertz.activate(.char("z")) == .insert("z"))
    }

    @Test func sharedChromeLocaleExtras() {
        var qwerty = OnScreenKeyboardState()
        qwerty.open(layout: .qwerty)
        #expect(qwerty.columnCount == 11)
        #expect(qwerty.rows[0][10] == .delete)
        #expect(qwerty.rows[1][10] == .char("'"))
        #expect(qwerty.rows[2][9] == .char(":"))
        #expect(qwerty.rows[2][10] == .char("_"))
        #expect(qwerty.rows[3][10] == .char("?"))

        var qwertz = OnScreenKeyboardState()
        qwertz.open(layout: .qwertz)
        #expect(qwertz.rows[1][10] == .char("ü"))
        #expect(qwertz.rows[2][9] == .char("ö"))
        #expect(qwertz.rows[3][10] == .char("ß"))

        var azerty = OnScreenKeyboardState()
        azerty.open(layout: .azerty)
        #expect(azerty.columnCount == 11)
        #expect(azerty.rows[1][0] == .char("a"))
        #expect(azerty.rows[1][10] == .char("é"))
        #expect(azerty.rows[2][9] == .char("m"))
        #expect(azerty.rows[2][10] == .char("à"))
        #expect(azerty.rows[3][9] == .char("è"))
        #expect(azerty.rows[3][10] == .char("ç"))

        var spanish = OnScreenKeyboardState()
        spanish.open(layout: .spanish)
        #expect(spanish.rows[2][9] == .char("ñ"))
        #expect(spanish.rows[3][10] == .char("¡"))

        var nordic = OnScreenKeyboardState()
        nordic.open(layout: .nordic)
        #expect(nordic.rows[2][9] == .char("å"))
        #expect(nordic.rows[1][10] == .char("ö"))
        nordic.holdShift = true
        #expect(nordic.activate(.char("ø")) == .insert("æ"))
    }

    @Test func layoutFromLanguageCode() {
        #expect(OnScreenKeyboardState.Layout.from(languageCode: "de") == .qwertz)
        #expect(OnScreenKeyboardState.Layout.from(languageCode: "fr") == .azerty)
        #expect(OnScreenKeyboardState.Layout.from(languageCode: "es") == .spanish)
        #expect(OnScreenKeyboardState.Layout.from(languageCode: "sv") == .nordic)
        #expect(OnScreenKeyboardState.Layout.from(languageCode: "en") == .qwerty)
    }

    @Test func shiftLayerHasNoDuplicateSymbols() {
        for layout in OnScreenKeyboardState.Layout.allCases {
            var seen = Set<String>()
            for row in OnScreenKeyboardState.grid(layout) {
                for key in row {
                    guard case .char(let c) = key else { continue }
                    #expect(seen.insert(c).inserted, "base \(c) twice in \(layout)")
                    if let alt = OnScreenKeyboardState.Key.shiftAlternates(for: layout)[c] {
                        #expect(seen.insert(alt).inserted, "\(layout) shift \(c)→\(alt) duplicates")
                    }
                }
            }
        }
    }

    @Test func shiftLayerURLSymbols() {
        var qwerty = OnScreenKeyboardState()
        qwerty.open(layout: .qwerty)
        qwerty.holdShift = true
        #expect(qwerty.activate(.char("'")) == .insert("\""))
        #expect(qwerty.activate(.char("@")) == .insert("#"))
        #expect(qwerty.activate(.char("0")) == .insert("="))
        // Base already has _ : ? — shift must not re-offer them.
        #expect(OnScreenKeyboardState.Key.shiftAlternates(for: .qwerty)["-"] == nil)
        #expect(OnScreenKeyboardState.Key.shiftAlternates(for: .qwerty)["."] == nil)
        #expect(OnScreenKeyboardState.Key.shiftAlternates(for: .qwerty)["/"] == nil)

        var qwertz = OnScreenKeyboardState()
        qwertz.open(layout: .qwertz)
        qwertz.holdShift = true
        #expect(qwertz.activate(.char("-")) == .insert("_"))
        #expect(qwertz.activate(.char(".")) == .insert(":"))
        #expect(qwertz.activate(.char("/")) == .insert("?"))
        #expect(qwertz.activate(.char("ß")) == .insert("&"))
        #expect(OnScreenKeyboardState.Key.char("ß").label(shift: true, layout: .qwertz) == "&")
    }
}
