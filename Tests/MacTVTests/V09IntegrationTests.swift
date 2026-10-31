import AppKit
import Foundation
import Testing
@testable import MacTV

@Suite @MainActor struct V09IntegrationTests {
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    @Test func profilesKeepIndependentPinsOrderAndAppIdentifiers() throws {
        try withFolder { folder in
            let first = AppLibrary(folder: folder)
            let other = AppLibrary(profileID: "other", folder: folder)
            let url = try #require(URL(string: "https://example.com"))
            let a = first.add(name: "Video", url: url, bundleID: nil)
            let b = other.add(name: "Video", url: url, bundleID: nil)
            #expect(a.id != b.id)
            #expect(first.setPinned("youtube", true))
            #expect(other.setPinned("netflix", true))
            #expect(first.move("hotstar", by: -1))
            let expected = first.services().map(\.id)
            #expect(AppLibrary(folder: folder).services().map(\.id) == expected)
            #expect(!other.isPinned("youtube"))
            #expect(!first.isPinned("netflix"))
            #expect(AppLibrary(profileID: "other", folder: folder).isPinned("netflix"))
        }
    }

    @Test func switchingProfilesPreservesFolderAndRestoresFavourites() throws {
        _ = NSApplication.shared
        try withFolder { folder in
            let profiles = ProfileStore(folder: folder)
            let second = profiles.add(named: "Second")
            let tv = TVController(library: AppLibrary(folder: folder), profiles: profiles)
            #expect(tv.setPinned("youtube", true))
            tv.switchProfile(to: second.id)
            #expect(tv.profile.id == second.id)
            #expect(tv.library.storageFolder == folder)
            #expect(!tv.isPinned("youtube"))
            #expect(tv.setPinned("netflix", true))
            tv.switchProfile(to: Profile.mainID)
            #expect(tv.isPinned("youtube"))
            #expect(!tv.isPinned("netflix"))
        }
    }

    @Test func sectionsRetainChildPanelsAndStatusFocus() throws {
        try withFolder { folder in
            let tv = TVController(library: AppLibrary(folder: folder))
            tv.settings = SettingsPanel(section: .apps, open: true, row: 1)
            tv.handleSettings(.select)
            #expect(tv.organizer != nil)
            tv.handleOrganizer(.back)
            #expect(tv.settings?.section == .apps && tv.settings?.row == 1)
            tv.settings?.row = 2
            tv.handleSettings(.select)
            #expect(tv.topShelfPreferences != nil)
            tv.handleTopShelfPreferences(.back)
            #expect(tv.settings?.section == .apps)
            #expect(SettingsPanel.Section.watching.rows.contains(.playbackCheck))
            tv.setFocus(.status(.profile))
            #expect(tv.setPinned("spotify", true))
            #expect(tv.focus == .status(.profile))
        }
    }

    @Test func controlCenterDismissesSettingsChildrenButProtectsSetup() throws {
        _ = NSApplication.shared
        try withFolder { folder in
            let tv = TVController(library: AppLibrary(folder: folder))
            tv.settings = SettingsPanel(section: .apps, open: true, row: 1)
            tv.openOrganizer()
            tv.handle(.controlCenter)
            #expect(tv.controlCenter != nil)
            #expect(tv.settings == nil && tv.organizer == nil)
            tv.handle(.controlCenter)
            tv.setup = SetupFlow()
            tv.handle(.controlCenter)
            #expect(tv.setup != nil && tv.controlCenter == nil)
        }
    }

    @Test func completedIconsStayWithOriginatingProfile() throws {
        _ = NSApplication.shared
        try withFolder { folder in
            let original = AppLibrary(folder: folder)
            let active = AppLibrary(profileID: "second", folder: folder)
            let app = original.add(name: "Video", url: URL(string: "https://example.com"), bundleID: nil)
            let tv = TVController(library: active)
            let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                NSColor.red.setFill(); NSBezierPath(rect: rect).fill(); return true
            }
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            tv.useIcon(png, for: app.id, in: original)
            #expect(FileManager.default.fileExists(atPath: original.iconFile(for: app.id).path))
            #expect(!active.containsAddedApp(app.id))
            let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("apps.json"))) as? [String: Any])
            let added = try #require(saved["added"] as? [[String: Any]])
            #expect(added.first?["accent"] != nil)
            original.remove(app.id)
            tv.useIcon(png, for: app.id, in: original)
            #expect(!FileManager.default.fileExists(atPath: original.iconFile(for: app.id).path))
        }
    }
}
