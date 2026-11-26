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
        let previous = TVController.removeHoldDurationOverride
        TVController.removeHoldDurationOverride = 0.05
        defer { TVController.removeHoldDurationOverride = previous }
        try body(TVController(library: AppLibrary(folder: folder)))
    }

    @Test func removeIsTheLastActionAndHoldDeletesOneApp() throws {
        try withTV { tv in
            let added = tv.library.add(name: "Disposable", url: URL(string: "https://disposable.example"), bundleID: nil)
            tv.reloadServices()
            tv.openOrganizer()
            tv.organizer?.selectedID = added.id
            #expect(tv.organizer?.action == .pin)
            tv.handleOrganizer(.move(.right))
            tv.handleOrganizer(.move(.right))
            tv.handleOrganizer(.move(.right))
            #expect(tv.organizer?.action == .remove)
            tv.handleOrganizer(.selectDown)
            #expect(tv.isHoldingRemove)
            tv.finishRemoveHold()
            #expect(tv.notices.toast == "Removed Disposable")
            #expect(!tv.library.containsAddedApp(added.id))
            #expect(!tv.arrangedServices.contains { $0.id == added.id })
        }
    }

    @Test func releasingSelectCancelsRemoveHold() throws {
        try withTV { tv in
            let apps = tv.arrangedServices.map(\.id)
            tv.openOrganizer()
            tv.organizer?.selectedID = apps[0]
            tv.organizer?.action = .remove
            tv.handleOrganizer(.selectDown)
            #expect(tv.isHoldingRemove)
            #expect(tv.removeHoldProgress >= 0)
            tv.handleOrganizer(.selectUp)
            #expect(!tv.isHoldingRemove)
            #expect(tv.removeHoldProgress == 0)
            #expect(tv.arrangedServices.map(\.id) == apps)
        }
    }

    @Test func movingAwayCancelsRemoveHold() throws {
        try withTV { tv in
            let apps = tv.arrangedServices.map(\.id)
            tv.openOrganizer()
            tv.organizer?.selectedID = apps[0]
            tv.organizer?.action = .remove
            tv.beginRemoveHold(for: apps[0])
            #expect(tv.isHoldingRemove)
            tv.handleOrganizer(.move(.down))
            #expect(!tv.isHoldingRemove)
            #expect(tv.arrangedServices.contains { $0.id == apps[0] })
        }
    }

    @Test func pinKeepsTheSlotAndMoveKeepsTheApp() throws {
        try withTV { tv in
            let apps = tv.arrangedServices.map(\.id)
            let target = apps[1]
            tv.openOrganizer()
            tv.organizer?.selectedID = target
            let slot = try #require(tv.arrangedServices.firstIndex { $0.id == target })

            tv.activateOrganizerAction(.pin, for: target)
            #expect(tv.isPinned(target))
            #expect(tv.organizer?.selectedID == tv.arrangedServices[slot].id)
            #expect(tv.organizer?.action == .pin)

            let moved = tv.arrangedServices[slot].id
            tv.activateOrganizerAction(.later, for: moved)
            #expect(tv.organizer?.selectedID == moved)
            #expect(tv.organizer?.action == .later)
            #expect(tv.arrangedServices.firstIndex { $0.id == moved } == slot + 1)
        }
    }

    @Test func selectionStaysOnTheSlotAfterRemove() throws {
        try withTV { tv in
            let apps = tv.arrangedServices.map(\.id)
            tv.openOrganizer()
            tv.activateOrganizerAction(.remove, for: apps[1])
            #expect(tv.organizer?.selectedID == apps[2])
            #expect(tv.organizer?.action == .remove)
            #expect(tv.library.isHidden(apps[1]))

            let last = try #require(tv.arrangedServices.last?.id)
            let previous = try #require(tv.arrangedServices.dropLast().last?.id)
            tv.activateOrganizerAction(.remove, for: last)
            #expect(tv.organizer?.selectedID == previous)

            #expect(tv.removeApp(previous))
            tv.reconcileOrganizerSelection()
            let keep = try #require(tv.organizer?.selectedID)
            #expect(tv.arrangedServices.contains { $0.id == keep })
        }
    }

    @Test func everyAppCanBeRemovedAndSuggestedRestoresTheBuiltIns() throws {
        try withTV { tv in
            let builtIn = tv.arrangedServices.map(\.id)
            tv.openOrganizer()
            for id in builtIn { tv.activateOrganizerAction(.remove, for: id) }
            #expect(tv.arrangedServices.isEmpty)
            #expect(tv.organizer?.selectedID == nil)
            #expect(tv.services.map(\.id) == ["add-app", "settings"])
            tv.handleOrganizer(.select)
            tv.handleOrganizer(.back)
            #expect(tv.organizer == nil)

            // Bulk restore (Settings / phone remote) is gone: Add App › Suggested toggles them back.
            #expect(SettingsPanel.Section.apps.rows == [.addApp, .arrangeApps, .topShelfPreferences, .homeLayout])
            #expect(tv.library.hiddenBuiltInCount == builtIn.count)

            tv.adder = AppAdder(tab: .suggested, row: 1, selected: 0)
            for id in builtIn {
                guard let index = tv.adderSuggestionRows.firstIndex(where: {
                    if case .item(.restore(let service)) = $0 { return service.id == id }
                    return false
                }) else {
                    Issue.record("missing Suggested restore for \(id)")
                    continue
                }
                tv.adder?.selected = index
                tv.addSelectedSuggestion()
            }
            #expect(tv.library.hiddenBuiltInCount == 0)
            #expect(tv.arrangedServices.map(\.id) == builtIn)
            #expect(tv.adder != nil)
        }
    }

    @Test func listStopsAtTheEndsAndSeekStepsActions() throws {
        try withTV { tv in
            let apps = tv.arrangedServices.map(\.id)
            tv.openOrganizer()
            tv.organizer?.selectedID = apps[0]
            tv.handleOrganizer(.move(.up))
            #expect(tv.organizer?.selectedID == apps[0])
            tv.handleOrganizer(.move(.down))
            #expect(tv.organizer?.selectedID == apps[1])
            tv.handleOrganizer(.move(.up))

            tv.handleOrganizer(.seek(forward: true))
            #expect(tv.organizer?.action == .earlier)
            tv.handleOrganizer(.seek(forward: false))
            #expect(tv.organizer?.action == .pin)
        }
    }

    @Test func aPressThatCantBeHeldRemovesOnTheSecondPress() throws {
        try withTV { tv in
            let apps = tv.arrangedServices.map(\.id)
            tv.openOrganizer()
            tv.organizer?.selectedID = apps[0]
            tv.organizer?.action = .remove
            tv.handleOrganizer(.select)
            #expect(!tv.isHoldingRemove)
            #expect(tv.organizer?.confirmingRemoveID == apps[0])
            #expect(tv.arrangedServices.map(\.id) == apps)
            // Anything else in between cancels it.
            tv.handleOrganizer(.move(.left))
            tv.handleOrganizer(.move(.right))
            #expect(tv.organizer?.confirmingRemoveID == nil)
            tv.handleOrganizer(.select)
            tv.handleOrganizer(.select)
            #expect(!tv.arrangedServices.contains { $0.id == apps[0] })
            #expect(tv.library.isHidden(apps[0]))
        }
    }
}
