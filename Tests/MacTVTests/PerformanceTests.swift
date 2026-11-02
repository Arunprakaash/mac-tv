import Combine
import Foundation
import Testing
@testable import MacTV

@Suite @MainActor
struct PerformanceTests {
    init() { AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) } }

    @Test
    func pointerTiltDoesNotRedrawTheWholeTV() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        tv.hover(0, tilt: .zero)

        var tvChanges = 0, tiltChanges = 0
        let watchers = [tv.objectWillChange.sink { tvChanges += 1 }, tv.pointerTilt.objectWillChange.sink { tiltChanges += 1 }]
        defer { watchers.forEach { $0.cancel() } }
        for step in 1...20 { tv.hover(0, tilt: CGSize(width: Double(step) / 50, height: 0)) }

        #expect(tvChanges == 0)
        #expect(tiltChanges == 20)
        #expect(tv.tilt.width == 0.4)
    }

    @Test
    func coreAudioVolumeIsAPercentage() {
        // Read-only: build machines may have no output, and HDMI outputs report no level.
        if let level = SystemControl.volume().level { #expect((0...100).contains(level)) }
    }
}
