import Foundation
import Testing
@testable import MacTV

@Suite @MainActor
struct DiagnosticReportTests {
    init() { AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) } }

    @Test
    func factsCoverEachAreaWithoutNames() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))

        let facts = DiagnosticReport.facts(tv)
        for heading in ["# Mac TV diagnostics", "## Displays", "## Sound", "## Remote and power", "## Crashes in the last 14 days"] {
            #expect(facts.contains(heading))
        }
        #expect(facts.contains("- Showing: Home"))
        // Device names often carry a person's name; only the kind of output is reported.
        for device in tv.audioDevices where device.name.count > 3 {
            #expect(!facts.contains(device.name))
        }
        #expect(!facts.contains(tv.profile.name))
    }

    @Test
    func sessionLogReadsWithoutFailing() {
        #expect(!DiagnosticReport.sessionLog(limit: 5).hasPrefix("Couldn't read the log"))
    }
}
