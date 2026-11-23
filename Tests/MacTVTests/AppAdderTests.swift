import AppKit
import Testing
@testable import MacTV

@Suite @MainActor
struct AppAdderTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    private func tempLibrary() -> (TVController, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        return (TVController(library: AppLibrary(folder: folder)), folder)
    }

    private func rowIndex(in tv: TVController, websiteID: String) -> Int? {
        tv.adderSuggestionRows.firstIndex {
            if case .item(.website(let service)) = $0 { return service.id == websiteID }
            return false
        }
    }

    private func rowIndex(in tv: TVController, restoreID: String) -> Int? {
        tv.adderSuggestionRows.firstIndex {
            if case .item(.restore(let service)) = $0 { return service.id == restoreID }
            return false
        }
    }

    @Test func shouldersCycleTabsFromAnyRow() {
        let (tv, folder) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        tv.adder = AppAdder(tab: .website, row: 2)

        tv.handleAdder(.seek(forward: true))
        #expect(tv.adder?.tab == .suggested)
        #expect(tv.adder?.row == 1)

        tv.handleAdder(.seek(forward: true))
        #expect(tv.adder?.tab == .macApp)
        #expect(tv.adder?.row == 1)

        if tv.adderTabs.contains(.steam) {
            tv.handleAdder(.seek(forward: true))
            #expect(tv.adder?.tab == .steam)
            #expect(tv.adder?.row == 1)
            tv.handleAdder(.seek(forward: false))
            #expect(tv.adder?.tab == .macApp)
        }
    }

    @Test func suggestedListsAllBuiltInsAndKeepsSitesOnHome() {
        let previous = Catalog.suggestionRegionOverride
        Catalog.suggestionRegionOverride = "DE"
        defer { Catalog.suggestionRegionOverride = previous }
        let (tv, folder) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        tv.library.setHidden("spotify", true)
        tv.reloadServices()

        #expect(tv.adderSuggestions.contains { if case .restore(let s) = $0 { return s.id == "spotify" }; return false })
        #expect(tv.adderSuggestions.contains { if case .restore(let s) = $0 { return s.id == "netflix" }; return false })
        #expect(tv.isOnHomeScreen(Catalog.services.first { $0.id == "netflix" }!))
        #expect(!tv.isOnHomeScreen(Catalog.services.first { $0.id == "spotify" }!))
        #expect(section(of: "disney", in: tv) == "Included")
        #expect(section(of: "joyn", in: tv) == "Suggested for you")

        _ = tv.addWebsite(name: "Disney+", address: "https://www.disneyplus.com")
        #expect(tv.adderSuggestions.contains { if case .website(let s) = $0 { return s.id == "disney" }; return false })
        #expect(tv.isOnHomeScreen(Catalog.websiteSuggestions.first { $0.id == "disney" }!))
    }

    @Test func suggestedForYouUsesMacRegionAndHidesForeignLocalsUntilMore() {
        let previous = Catalog.suggestionRegionOverride
        defer { Catalog.suggestionRegionOverride = previous }
        let (tv, folder) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }

        Catalog.suggestionRegionOverride = "DE"
        #expect(section(of: "disney", in: tv) == "Included")
        #expect(section(of: "joyn", in: tv) == "Suggested for you")
        #expect(section(of: "itvx", in: tv) == nil)
        #expect(section(of: "hotstar", in: tv) == "Included")
        #expect(section(of: "hulu", in: tv) == nil)
        #expect(tv.adderSuggestionRows.contains { if case .moreServices = $0 { return true }; return false })

        Catalog.suggestionRegionOverride = "GB"
        #expect(section(of: "itvx", in: tv) == "Suggested for you")
        #expect(section(of: "channel4", in: tv) == "Suggested for you")
        #expect(section(of: "disney", in: tv) == "Included")

        Catalog.suggestionRegionOverride = "IN"
        #expect(section(of: "hotstar", in: tv) == "Included")
        #expect(section(of: "sonyliv", in: tv) == "Suggested for you")
        #expect(section(of: "disney", in: tv) == "Included")

        Catalog.suggestionRegionOverride = "US"
        tv.adder = AppAdder(tab: .suggested, row: 1, moreServicesExpanded: false)
        #expect(section(of: "hulu", in: tv) == "Suggested for you")
        #expect(section(of: "joyn", in: tv) == nil)
        #expect(section(of: "disney", in: tv) == "Included")

        guard let more = tv.adderSuggestionRows.firstIndex(where: { if case .moreServices = $0 { return true }; return false }) else {
            Issue.record("More services missing"); return
        }
        tv.adder?.selected = more
        tv.addSelectedSuggestion()
        #expect(tv.adder?.moreServicesExpanded == true)
        #expect(section(of: "joyn", in: tv) == nil) // still under More, not Suggested for you
        #expect(tv.adderSuggestions.contains { if case .website(let s) = $0 { return s.id == "joyn" }; return false })
        #expect(tv.adderSuggestions.contains { if case .restore(let s) = $0 { return s.id == "itvx" }; return false })
    }

    @Test func regionGatedBuiltInAddsAsWebsiteWhenLocaleMismatch() {
        let previous = Catalog.suggestionRegionOverride
        Catalog.suggestionRegionOverride = "GB"
        defer { Catalog.suggestionRegionOverride = previous }
        let (tv, folder) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let itvx = Catalog.services.first { $0.id == "itvx" }!
        // Mac Locale is usually not GB in CI; built-in stays unavailable until added as a site.
        guard !itvx.isAvailable else { return }
        tv.adder = AppAdder(tab: .suggested, row: 1)
        guard let index = rowIndex(in: tv, restoreID: "itvx") else {
            Issue.record("itvx suggestion missing"); return
        }
        tv.adder?.selected = index
        tv.addSelectedSuggestion()
        #expect(tv.isOnHomeScreen(itvx))
        #expect(tv.adder != nil)
    }

    /// Header above a website/restore id: Included, Suggested for you, or nil if only under More (collapsed).
    private func section(of id: String, in tv: TVController) -> String? {
        var current: String?
        for row in tv.adderSuggestionRows {
            switch row {
            case .header(let title): current = title
            case .moreServices: current = nil
            case .item(let pick) where pick.service.id == id: return current
            case .item: break
            }
        }
        return nil
    }

    @Test func selectingSuggestionRestoresHiddenBuiltInAndStaysOpen() {
        let previous = Catalog.suggestionRegionOverride
        Catalog.suggestionRegionOverride = "DE"
        defer { Catalog.suggestionRegionOverride = previous }
        let (tv, folder) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        tv.library.setHidden("prime", true)
        tv.reloadServices()
        tv.adder = AppAdder(tab: .suggested, row: 1, selected: 0)
        guard let index = rowIndex(in: tv, restoreID: "prime") else {
            Issue.record("prime restore missing"); return
        }
        tv.adder?.selected = index
        tv.addSelectedSuggestion()
        #expect(!tv.library.isHidden("prime"))
        #expect(tv.services.contains { $0.id == "prime" })
        #expect(tv.adder != nil)
        #expect(tv.isOnHomeScreen(Catalog.services.first { $0.id == "prime" }!))
    }

    @Test func selectingSuggestionOnHomeRemovesAndFlashesRemoved() {
        let previous = Catalog.suggestionRegionOverride
        Catalog.suggestionRegionOverride = "DE"
        defer { Catalog.suggestionRegionOverride = previous }
        let (tv, folder) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = tv.addWebsite(name: "Disney+", address: "https://www.disneyplus.com")
        tv.adder = AppAdder(tab: .suggested, row: 1)
        guard let index = rowIndex(in: tv, websiteID: "disney") else {
            Issue.record("disney suggestion missing"); return
        }
        let pickID = tv.adderSuggestionRows[index].id
        tv.adder?.selected = index
        tv.addSelectedSuggestion()

        #expect(!tv.isOnHomeScreen(Catalog.websiteSuggestions.first { $0.id == "disney" }!))
        #expect(tv.adder != nil)
        #expect(tv.adder?.removedFlashID == pickID)
        #expect(tv.adderRemovedFlash(for: pickID))
    }

    @Test func selectingSuggestionAddsWebsiteAndStaysOpen() {
        let previous = Catalog.suggestionRegionOverride
        Catalog.suggestionRegionOverride = "DE"
        defer { Catalog.suggestionRegionOverride = previous }
        let (tv, folder) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        tv.adder = AppAdder(tab: .suggested, row: 1)
        guard let index = rowIndex(in: tv, websiteID: "disney") else {
            Issue.record("disney suggestion missing"); return
        }
        tv.adder?.selected = index
        tv.addSelectedSuggestion()
        #expect(tv.isOnHomeScreen(Catalog.websiteSuggestions.first { $0.id == "disney" }!))
        #expect(tv.adder != nil)
    }

    @Test func matchesSuggestionRegionTreatsNilAsWorldwide() {
        let disney = Catalog.websiteSuggestions.first { $0.id == "disney" }!
        let joyn = Catalog.websiteSuggestions.first { $0.id == "joyn" }!
        #expect(Catalog.matchesSuggestionRegion(disney, region: "US"))
        #expect(Catalog.matchesSuggestionRegion(joyn, region: "DE"))
        #expect(!Catalog.matchesSuggestionRegion(joyn, region: "US"))
    }

    @Test func newShelfLanguagesAreAddedOnceAndStayOffWhenTurnedOff() {
        let defaults = UserDefaults.standard
        let savedPreferences = defaults.object(forKey: "topShelfPreferences")
        let savedFlag = defaults.object(forKey: "topShelfAddedLanguages")
        defer {
            defaults.set(savedPreferences, forKey: "topShelfPreferences")
            defaults.set(savedFlag, forKey: "topShelfAddedLanguages")
        }
        defaults.removeObject(forKey: "topShelfAddedLanguages")
        ShelfPreferences(region: "", languages: ["English", "Hindi"]).save()
        #expect(ShelfPreferences.load().languages == ["Dutch", "English", "French", "German", "Hindi", "Italian", "Portuguese"])

        var preferences = ShelfPreferences.load()
        preferences.languages.removeAll { $0 == "French" }
        preferences.save()
        #expect(!ShelfPreferences.load().languages.contains("French"))
        #expect(!ShelfPreferences.load().languages.contains("French"))

        // A new install starts with them, so turning one off there sticks too.
        defaults.removeObject(forKey: "topShelfPreferences")
        defaults.removeObject(forKey: "topShelfAddedLanguages")
        var fresh = ShelfPreferences.load()
        fresh.languages.removeAll { $0 == "German" }
        fresh.save()
        #expect(!ShelfPreferences.load().languages.contains("German"))
    }
}
