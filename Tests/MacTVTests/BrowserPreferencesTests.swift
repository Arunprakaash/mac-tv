import Foundation
import Testing
@testable import MacTV

@Suite @MainActor
struct BrowserPreferencesTests {
    @Test func defaultsFollowAvailability() throws {
        let suite = "MacTV.BrowserPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(BrowserPreferences(defaults: defaults, braveAvailable: { true }).choice(for: "main") == .brave)
        #expect(BrowserPreferences(defaults: defaults, braveAvailable: { false }).choice(for: "main") == .embedded)
    }

    @Test func savedChoicesSurviveAvailabilityChanges() throws {
        let suite = "MacTV.BrowserPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let installed = BrowserPreferences(defaults: defaults, braveAvailable: { true })
        installed.setChoice(.embedded, for: "main")
        installed.setChoice(.brave, for: "other")
        let unavailable = BrowserPreferences(defaults: defaults, braveAvailable: { false })
        #expect(unavailable.choice(for: "main") == .embedded)
        #expect(unavailable.choice(for: "other") == .brave)
        #expect(installed.choice(for: "main") == .embedded)
        #expect(installed.choice(for: "new") == .brave)
        #expect(unavailable.choice(for: "new") == .embedded)
    }
}
