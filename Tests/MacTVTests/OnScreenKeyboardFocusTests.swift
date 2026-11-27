import AppKit
import Testing
@testable import MacTV

@Suite @MainActor
struct OnScreenKeyboardFocusTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    @Test func adderWebsiteFieldsCountAsTyping() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))

        tv.adder = AppAdder(tab: .website, row: 1)
        #expect(tv.isTypingFieldFocused)
        #expect(tv.canShowOnScreenKeyboard)

        tv.adder?.row = 0
        #expect(!tv.isTypingFieldFocused)
        #expect(tv.canShowOnScreenKeyboard)

        tv.adder = nil
        #expect(!tv.canShowOnScreenKeyboard)
    }

    @Test func openKeyboardOnSelectOnlyWithControllerInputOnTypingField() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))

        tv.adder = AppAdder(tab: .website, row: 1)
        #expect(!tv.showsOpenKeyboardOnSelect)
        #expect(!tv.openKeyboardFromControllerSelect())

        tv.controller = ControllerInfo(name: "Pad")
        tv.lastInputKind = .keyboard
        #expect(!tv.showsOpenKeyboardOnSelect)
        #expect(!tv.openKeyboardFromControllerSelect())

        tv.lastInputKind = .controller
        #expect(tv.showsOpenKeyboardOnSelect)
        #expect(tv.openKeyboardFromControllerSelect())
        #expect(tv.onScreenKeyboard.isOpen)

        tv.closeOnScreenKeyboard()
        tv.lastInputKind = .remote
        #expect(!tv.showsOpenKeyboardOnSelect)
        #expect(!tv.openKeyboardFromControllerSelect())
    }

    @Test func stepKeyboardLayoutGoesBothWays() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        tv.keyboardLayout = .qwerty
        tv.stepKeyboardLayout(forward: true)
        #expect(tv.keyboardLayout == .qwertz)
        tv.stepKeyboardLayout(forward: false)
        #expect(tv.keyboardLayout == .qwerty)
    }

    @Test func autoShowPreferenceDefaultsOn() {
        let suite = "MacTV.OSKFocus.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.autoShowOnScreenKeyboard)
    }

    @Test func webAutoShowOnlyWhenControllerIsActiveInput() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        // Adder counts as a typing surface for canShow; webTyping drives auto-show.
        tv.adder = AppAdder(tab: .website, row: 1)
        tv.controller = ControllerInfo(name: "Pad")
        tv.lastInputKind = .keyboard

        tv.setWebTyping(true)
        #expect(!tv.onScreenKeyboard.isOpen)

        tv.lastInputKind = .controller
        tv.setWebTyping(false)
        tv.setWebTyping(true)
        #expect(tv.onScreenKeyboard.isOpen)

        tv.setWebTyping(false)
        #expect(!tv.onScreenKeyboard.isOpen)
    }

    @Test func profileNamingMoveBetweenFieldAndCreate() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        tv.controller = ControllerInfo(name: "Pad")
        tv.lastInputKind = .controller
        tv.profilePicker = ProfilePicker(naming: "Alex")

        #expect(tv.isTypingFieldFocused)
        #expect(!(tv.profilePicker?.namingOnCreate ?? true))

        tv.handleProfiles(.move(.down))
        #expect(tv.profilePicker?.namingOnCreate == true)
        #expect(!tv.isTypingFieldFocused)

        tv.handleProfiles(.move(.up))
        #expect(tv.profilePicker?.namingOnCreate == false)
        #expect(tv.isTypingFieldFocused)
        #expect(tv.openKeyboardFromControllerSelect())
        #expect(tv.onScreenKeyboard.isOpen)
    }
}
