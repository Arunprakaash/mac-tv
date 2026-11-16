import Foundation
import Testing
@testable import MacTV

@Suite
@MainActor
struct YouTubeAdBlockingTests {
    @Test func rulesJSONIsValidAndCoversMajorAdHosts() throws {
        let data = try #require(YouTubeAdBlocking.rulesJSON.data(using: .utf8))
        let rules = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(rules.count == YouTubeAdBlocking.blockedHosts.count + YouTubeAdBlocking.blockedURLFilters.count)
        #expect(YouTubeAdBlocking.blockedHosts.contains("doubleclick.net"))
        #expect(YouTubeAdBlocking.blockedHosts.contains("googlesyndication.com"))
        let filters = YouTubeAdBlocking.blockedURLFilters
        #expect(filters.contains { $0.contains("youtube\\.com/pagead") })
        let first = try #require(rules.first)
        let trigger = try #require(first["trigger"] as? [String: Any])
        #expect((trigger["if-domain"] as? [String]) == YouTubeAdBlocking.ruleDomains)
    }

    @Test func pageScriptOnlyMentionsYouTubeHosts() {
        let script = YouTubeAdBlocking.pageScript
        #expect(script.contains("youtube"))
        #expect(!script.contains("netflix"))
        #expect(!script.contains("primevideo"))
    }

    @Test func pageScriptRecoversStuckAdFrames() {
        let script = YouTubeAdBlocking.pageScript
        #expect(script.contains("playbackRate"))
        #expect(script.contains("postSkip"))
        #expect(script.contains("readyState"))
        #expect(script.contains("isInlinePlaybackNoAd"))
        #expect(script.contains("forceLeaveAd") || script.contains("buffered"))
        #expect(!YouTubeAdBlocking.blockedHosts.contains("imasdk.googleapis.com"))
    }

    @Test func blockYouTubeAdsDefaultsOn() throws {
        let suite = "MacTV.YouTubeAdBlockingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.blockYouTubeAds == true)
        preferences.blockYouTubeAds = false
        #expect(Preferences(defaults: defaults).blockYouTubeAds == false)
    }

}
