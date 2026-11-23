import Foundation
import Testing
@testable import MacTV

@Suite @MainActor
struct AppRemovalTests {
    private func withTV(_ body: (TVController) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(TVController(library: AppLibrary(folder: folder)))
    }

    @Test func theCheckboxIsTheFirstActionAndTicksTheApp() throws {
        try withTV { tv in
            tv.openOrganizer()
            tv.organizer?.selectedID = "youtube"
            #expect(tv.organizer?.action == .pin)
            tv.handleOrganizer(.move(.left))
            tv.handleOrganizer(.move(.left))
            #expect(tv.organizer?.action == .check)
            tv.handleOrganizer(.select)
            #expect(tv.organizer?.checked == ["youtube"])
            tv.handleOrganizer(.move(.down))
            tv.handleOrganizer(.select)
            let second = try #require(tv.organizer?.selectedID)
            #expect(tv.organizer?.checked == ["youtube", second])
            // Ticking again unticks; pinning and moving keep the ticks.
            tv.handleOrganizer(.select)
            #expect(tv.organizer?.checked == ["youtube"])
            tv.activateOrganizerAction(.pin, for: second)
            #expect(tv.organizer?.checked == ["youtube"])
            // A click ticks without moving the remote's focus onto the checkbox.
            tv.toggleChecked("prime")
            #expect(tv.organizer?.checked == ["youtube", "prime"])
            #expect(tv.organizer?.action == .pin && tv.organizer?.selectedID == second)
            #expect(tv.services.contains { $0.id == "youtube" })
        }
    }

    @Test func deleteRemovesOnlyTheTickedApps() throws {
        try withTV { tv in
            let added = tv.library.add(name: "Disposable", url: URL(string: "https://disposable.example"), bundleID: nil)
            tv.reloadServices()
            tv.openOrganizer()
            let before = tv.arrangedServices.map(\.id)
            // Delete with nothing ticked does nothing.
            tv.handleOrganizer(.deleteBackward)
            #expect(tv.arrangedServices.map(\.id) == before)

            tv.activateOrganizerAction(.check, for: "prime")
            tv.activateOrganizerAction(.check, for: added.id)
            // The first press only asks; moving away cancels it.
            tv.handleOrganizer(.deleteBackward)
            #expect(tv.organizer?.confirmingDelete == true)
            #expect(tv.arrangedServices.map(\.id) == before)
            tv.handleOrganizer(.move(.down))
            #expect(tv.organizer?.confirmingDelete == false)
            tv.handleOrganizer(.deleteBackward)
            tv.handleOrganizer(.deleteBackward)
            #expect(tv.notices.toast == "Deleted 2 apps")
            #expect(tv.arrangedServices.map(\.id) == before.filter { $0 != "prime" && $0 != added.id })
            #expect(tv.library.isHidden("prime"))
            #expect(!tv.library.containsAddedApp(added.id))
            #expect(tv.organizer?.checked.isEmpty == true)
        }
    }

    @Test func selectionMovesToTheAppThatTakesItsPlace() throws {
        try withTV { tv in
            let apps = tv.arrangedServices.map(\.id)
            tv.openOrganizer()
            tv.activateOrganizerAction(.check, for: apps[1])
            tv.activateOrganizerAction(.check, for: apps[2])
            #expect(tv.organizer?.selectedID == apps[2])
            tv.handleOrganizer(.deleteBackward)
            tv.handleOrganizer(.deleteBackward)
            #expect(tv.organizer?.selectedID == apps[3])

            // The last row falls back to the one before it.
            let last = try #require(tv.arrangedServices.last?.id)
            let previous = try #require(tv.arrangedServices.dropLast().last?.id)
            tv.activateOrganizerAction(.check, for: last)
            tv.handleOrganizer(.deleteBackward)
            tv.handleOrganizer(.deleteBackward)
            #expect(tv.organizer?.selectedID == previous)

            // A ticked app removed from the phone drops out of the ticks.
            tv.activateOrganizerAction(.check, for: previous)
            #expect(tv.removeApp(previous))
            tv.reconcileOrganizerSelection()
            #expect(tv.organizer?.checked.isEmpty == true)
        }
    }

    @Test func everyAppCanBeRemovedAndSettingsRestoresTheBuiltIns() throws {
        try withTV { tv in
            let builtIn = tv.arrangedServices.map(\.id)
            tv.openOrganizer()
            for id in builtIn { tv.activateOrganizerAction(.check, for: id) }
            tv.handleOrganizer(.deleteBackward)
            tv.handleOrganizer(.deleteBackward)
            #expect(tv.arrangedServices.isEmpty)
            #expect(tv.organizer?.selectedID == nil)
            #expect(tv.services.map(\.id) == ["add-app", "settings"])
            tv.handleOrganizer(.select)
            tv.handleOrganizer(.back)
            #expect(tv.organizer == nil)

            #expect(SettingsPanel.Section.apps.rows.last == .restoreApps)
            #expect(tv.library.hiddenBuiltInCount == builtIn.count)
            tv.settings = SettingsPanel(section: .apps, open: true)
            tv.activateSetting(.restoreApps)
            #expect(tv.library.hiddenBuiltInCount == 0)
            #expect(tv.arrangedServices.map(\.id) == builtIn)
            tv.activateSetting(.restoreApps)
            #expect(tv.arrangedServices.map(\.id) == builtIn)
        }
    }
}
