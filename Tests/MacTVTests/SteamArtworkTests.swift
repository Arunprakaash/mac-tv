import AppKit
import Testing
@testable import MacTV

@Suite
struct SteamArtworkTests {
    @Test
    func bigPictureHasNoLibraryHero() async {
        #expect(await SteamLibrary.hero(for: SteamLibrary.bigPicture.appID) == nil)
    }

    @Test
    func shelfArtSamplesCoverKnownAAATitles() {
        let ids = Set(SteamLibrary.shelfArtSamples.map(\.appID))
        #expect(ids.contains("292030")) // The Witcher 3
        #expect(SteamLibrary.shelfArtSamples.count >= 4)
    }

    @Test @MainActor
    func heroFileSitsBesideTileIcon() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = AppLibrary(folder: folder)
        #expect(library.heroFile(for: "user-stardewvalley").lastPathComponent == "user-stardewvalley-hero.jpg")
        #expect(library.iconFile(for: "user-stardewvalley").lastPathComponent == "user-stardewvalley.png")
    }

    @Test
    func shelfMarkSitsAboveTheDockBand() {
        #expect(TileArt.shelfDockClearance == 320)
        #expect(TileArt.shelfMarkCenterY < 0.5)
        #expect(TileArt.shelfMarkCenterY == (TileArt.shelfSize.height - TileArt.shelfDockClearance) / (2 * TileArt.shelfSize.height))
    }

    @Test @MainActor
    func addAppAndSettingsHaveTileArt() {
        let add = Catalog.services.first { $0.id == "add-app" }!
        let settings = Catalog.services.first { $0.id == "settings" }!
        #expect(Icons.tile(for: add) != nil)
        #expect(Icons.shelfArt(for: add) != nil)
        #expect(Icons.tile(for: settings) != nil)
        #expect(Icons.shelfArt(for: settings) != nil)
    }
}

@Suite @MainActor
struct SteamShelfArtTests {
    @Test func artIsReadOnceUntilItChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("steam-art-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("game-hero.jpg")
        #expect(SteamShelfArt.image(at: file) == nil)

        let image = NSImage(size: NSSize(width: 64, height: 36), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill(); return true
        }
        let jpeg = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
            .representation(using: .jpeg, properties: [:]))
        try jpeg.write(to: file)
        // Remembered as missing until told the file changed, so a redraw never touches the disk.
        #expect(SteamShelfArt.image(at: file) == nil)
        SteamShelfArt.forget(file)
        let art = try #require(SteamShelfArt.image(at: file))
        #expect(art.size == NSSize(width: 64, height: 36))
        #expect(SteamShelfArt.image(at: file) === art)
        SteamShelfArt.forget(file)
    }
}
