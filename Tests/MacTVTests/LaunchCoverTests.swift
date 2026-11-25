import AppKit
import Testing
@testable import MacTV

/// The Starting cover: Home asks it to play backwards first, a second Home (or the animation ending)
/// tears it down, and a cancelled launch can't be marked ready afterwards.
@Suite @MainActor struct LaunchCoverTests {
    private func withTV(_ body: (TVController) throws -> Void) throws {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(TVController(library: AppLibrary(folder: folder)))
    }

    @Test func homeReversesTheCoverThenTearsItDown() throws {
        try withTV { tv in
            let service = try #require(tv.services.first { $0.id == "netflix" })
            tv.beginLaunchCover(service)
            #expect(tv.launchCover?.ready == false)
            tv.goHome()
            #expect(tv.launchCover?.canceling == true)
            // Ready can't arrive for a launch that's being cancelled.
            tv.markLaunchCoverReady()
            #expect(tv.launchCover?.ready == false)
            tv.completeLaunchCoverCancel()
            #expect(tv.launchCover == nil)
            #expect(!tv.launchCoverPinned)
        }
    }

    @Test func readyHandsOffAndFinishingClearsIt() throws {
        try withTV { tv in
            let service = try #require(tv.services.first { $0.id == "youtube" })
            tv.beginLaunchCover(service)
            tv.markLaunchCoverReady()
            #expect(tv.launchCover?.ready == true)
            tv.finishLaunchCover()
            #expect(tv.launchCover == nil)
        }
    }
}
