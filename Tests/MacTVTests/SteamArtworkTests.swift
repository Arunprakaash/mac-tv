import Foundation
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
}
