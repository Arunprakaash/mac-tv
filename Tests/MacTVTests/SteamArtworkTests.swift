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

    @Test
    func chartBootstrapIsTenUniqueControllerSeedIDs() {
        let ids = SteamLibrary.chartBootstrapGames.map(\.appID)
        #expect(ids.count == 10)
        #expect(Set(ids).count == 10)
        #expect(ids.contains("252950")) // Rocket League
        #expect(ids.contains("550"))    // Left 4 Dead 2
        #expect(!ids.contains(SteamLibrary.bigPicture.appID))
    }

    @Test
    func bestOfYearControllerUsesAPIType4NotStoreTabIndexOrVR() {
        // Store URL ?tab=5 is Controller, but GetYearTopAppReleases type 5 is VR (Half-Life: Alyx).
        #expect(SteamLibrary.bestOfYearControllerType == 4)
        #expect(SteamLibrary.bestOfYearVRType == 5)
        let json = Data(#"""
        {"response":{"top_app_list":[
          {"appid":730,"type":1},
          {"appid":252950,"type":4},
          {"appid":250900,"type":4},
          {"appid":546560,"type":5},
          {"appid":268910,"type":4}
        ]}}
        """#.utf8)
        let ids = SteamLibrary.bestOfYearControllerAppIDs(in: json, limit: 100)
        #expect(ids == ["252950", "250900", "268910"])
        #expect(!ids.contains("546560")) // HL: Alyx — VR tab / type 5
        #expect(SteamLibrary.bestOfYearControllerAppIDs(in: json, limit: 2) == ["252950", "250900"])
        #expect(SteamLibrary.bestOfYearControllerAppIDs(in: Data("{}".utf8)).isEmpty)
    }

    @Test
    func rtimeYearIsJanuaryFirstUTC() {
        #expect(SteamLibrary.rtimeYear(2025) == 1_735_689_600)
        #expect(SteamLibrary.rtimeYear(2024) == 1_704_067_200)
    }

    @Test
    func chartYearStaysThroughTheFollowingCalendarYear() {
        // Chart 2025: keep in 2025–2026; first look for 2026 in calendar 2027.
        #expect(!SteamLibrary.shouldRefreshChart(savedYear: 2025, calendarYear: 2025))
        #expect(!SteamLibrary.shouldRefreshChart(savedYear: 2025, calendarYear: 2026))
        #expect(SteamLibrary.shouldRefreshChart(savedYear: 2025, calendarYear: 2027))
    }

    @Test
    func libraryHeroSkipsBigPicture() async {
        #expect(await SteamLibrary.libraryHero(for: SteamLibrary.bigPicture.appID) == nil)
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
