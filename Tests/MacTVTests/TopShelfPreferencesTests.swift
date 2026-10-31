import Foundation
import Testing
@testable import MacTV

@Suite @MainActor
struct TopShelfPreferencesTests {
    @Test
    func languageSelectionIncludesAllOrSelectedOnly() {
        // Out of the box: the languages people here watch, not every language.
        var preferences = ShelfPreferences()
        #expect(preferences.includes(language: "Tamil"))
        #expect(!preferences.includes(language: "Russian"))
        // An empty list means all languages.
        preferences.languages = []
        #expect(preferences.includes(language: nil))
        #expect(preferences.includes(language: "Russian"))
        preferences.languages = ["Tamil", "Japanese"]
        #expect(preferences.includes(language: "Tamil"))
        #expect(!preferences.includes(language: "English"))
        #expect(!preferences.includes(language: nil))
    }

    @Test
    func searchEncodesProgrammeAndRejectsUnsupportedService() throws {
        let query = "மழை & Snow / 雪"
        let netflix = try #require(ShelfSearch.url(serviceID: "netflix", query: query))
        #expect(URLComponents(url: netflix, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == query)
        let spotify = try #require(ShelfSearch.url(serviceID: "spotify", query: query))
        #expect(spotify.path.removingPercentEncoding == "/search/" + query)
        #expect(ShelfSearch.url(serviceID: "hotstar", query: query) == nil)
        #expect(ShelfSearch.url(serviceID: "other", query: query) == nil)
    }
}

extension TopShelfPreferencesTests {
    @Test
    func cachedListsFollowTheirPreferenceDependencies() throws {
        let image = try #require(URL(string: "https://example.com/image.jpg"))
        let show = TopShelfFeed.Show(id: 1, name: "Example", image: image)
        let lists = ["netflix": [show], "spotify": [show], "ytmusic": [show]]
        let old = ShelfPreferences(region: "GB", languages: [])
        let languageChange = ShelfPreferences(region: "GB", languages: ["Tamil"])
        let regionChange = ShelfPreferences(region: "IN", languages: [])
        #expect(TopShelfFeed.reusableLists(lists, from: old, to: old) == lists)
        #expect(Set(TopShelfFeed.reusableLists(lists, from: old, to: languageChange).keys) == Set(["spotify", "ytmusic"]))
        #expect(TopShelfFeed.reusableLists(lists, from: old, to: regionChange).isEmpty)
    }
}
