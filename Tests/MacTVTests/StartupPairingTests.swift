import Foundation
import Testing
@testable import MacTV

@Suite @MainActor struct StartupPairingTests {
    private func withController(_ body: (TVController) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(TVController(library: AppLibrary(folder: folder)))
    }

    @Test func guestsCannotNavigateOwnerSettingsOrTypeIntoTheMac() throws {
        try withController { tv in
            tv.settings = SettingsPanel()
            #expect(!tv.handleGuestCommand(.move(.down)))
            #expect(!tv.handleGuestCommand(.select))
            #expect(!tv.handleGuestCommand(.text("private setting")))
            #expect(!tv.handleGuestCommand(.setting("keepMacAwake", false)))
            #expect(tv.settings != nil)
        }
    }

    @Test func reconnectDismissesStartupQRButKeepsManuallyOpenedQR() throws {
        try withController { tv in
            tv.offerStartupPairing()
            #expect(tv.pairing)
            _ = tv.remoteState()
            #expect(!tv.pairing)
            tv.pairing = true
            _ = tv.remoteState()
            #expect(tv.pairing)
        }
    }

    @Test func waitsForSetupAndProfileSelection() throws {
        try withController { tv in
            tv.setup = SetupFlow(step: .privacy, onlyPrivacy: true)
            tv.profilePicker = ProfilePicker()
            tv.offerStartupPairing()
            #expect(!tv.pairing)
            tv.finishSetup()
            #expect(!tv.pairing)
            tv.handleProfiles(.back)
            #expect(tv.pairing)
        }
    }

    @Test func phoneConnectingDuringProfileSelectionCancelsDeferredQR() throws {
        try withController { tv in
            tv.profilePicker = ProfilePicker()
            tv.offerStartupPairing()
            _ = tv.remoteState()
            tv.handleProfiles(.back)
            #expect(!tv.pairing)
        }
    }
}
