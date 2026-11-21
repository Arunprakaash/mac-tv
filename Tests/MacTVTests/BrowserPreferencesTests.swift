import Foundation
import Testing
@testable import MacTV

@Suite
struct BrowserPreferencesTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "MacTV.BrowserPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test
    func choicesArePersistedPerProfileAndDefaultToBuiltIn() throws {
        try withDefaults { defaults in
            let preferences = BrowserPreferences(defaults: defaults)
            #expect(preferences.choice(for: "main") == .embedded)
            preferences.setChoice(.brave, for: "main")
            preferences.setChoice(.embedded, for: "other")
            preferences.setChoice(.app("com.apple.Safari"), for: "third")
            let reloaded = BrowserPreferences(defaults: defaults)
            #expect(reloaded.choice(for: "main") == .brave)
            #expect(reloaded.choice(for: "other") == .embedded)
            #expect(reloaded.choice(for: "third") == .app("com.apple.Safari"))
            #expect(reloaded.choice(for: "new") == .embedded)
        }
    }

    @Test
    func valuesStoredByEarlierVersionsStillLoad() throws {
        try withDefaults { defaults in
            defaults.set(["a": "embedded", "b": "brave", "c": ""], forKey: "websitePlayerByProfile")
            let preferences = BrowserPreferences(defaults: defaults)
            #expect(preferences.choice(for: "a") == .embedded)
            #expect(preferences.choice(for: "b") == .brave)
            #expect(preferences.choice(for: "c") == .embedded)
        }
    }

    @Test
    func rawValuesRoundTripAndBraveIsNeverAnOtherBrowser() {
        for choice in [BrowserChoice.embedded, .brave, .app("org.mozilla.firefox")] {
            #expect(BrowserChoice(rawValue: choice.rawValue) == choice)
        }
        #expect(BrowserChoice(rawValue: "com.brave.Browser") == .brave)
        #expect(BrowserChoice(rawValue: "") == nil)
    }

    @Test
    func onlyChromiumBrowsersCanOpenASiteAsAnApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mactv-apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, files: [String]) throws -> URL {
            let url = root.appendingPathComponent("\(name).app")
            for file in files {
                let path = url.appendingPathComponent("Contents/Frameworks").appendingPathComponent(file)
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: path.path, contents: Data())
            }
            return url
        }
        let brave = try app("Brave Browser", files: ["Brave Browser Framework.framework/Helpers/app_mode_loader"])
        let discord = try app("Discord", files: ["Electron Framework.framework/Helpers/chrome_crashpad_handler",
                                                 "Discord Helper (Renderer).app/Contents/Info.plist"])
        let safari = try app("Safari", files: [])
        #expect(BrowserDiscovery.supportsAppMode(brave))
        #expect(!BrowserDiscovery.supportsAppMode(discord))
        #expect(!BrowserDiscovery.supportsAppMode(safari))
    }

    @Test
    func discoveryKeepsAppsThatOpenBothLinksAndPages() {
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        let firefox = URL(fileURLWithPath: "/Applications/Firefox.app")
        let firefoxCopy = URL(fileURLWithPath: "/Users/me/Applications/Firefox.app")
        let mailer = URL(fileURLWithPath: "/Applications/Link Opener.app")
        let editor = URL(fileURLWithPath: "/Applications/Editor.app")
        let macTV = URL(fileURLWithPath: "/Applications/Mac TV.app")
        let info: [URL: InstalledBrowser] = [
            safari: .init(bundleID: "com.apple.Safari", name: "Safari"),
            firefox: .init(bundleID: "org.mozilla.firefox", name: "Firefox"),
            firefoxCopy: .init(bundleID: "org.mozilla.firefox", name: "Firefox"),
            mailer: .init(bundleID: "example.linkopener", name: "Link Opener"),
            editor: .init(bundleID: "example.editor", name: "Editor"),
            macTV: .init(bundleID: "com.example.mactv", name: "Mac TV"),
        ]
        let browsers = BrowserDiscovery.browsers(
            httpsHandlers: [safari, mailer, firefox, firefoxCopy, macTV, URL(fileURLWithPath: "/Applications/Gone.app")],
            htmlHandlers: [editor, firefox, firefoxCopy, safari, macTV, URL(fileURLWithPath: "/Applications/Gone.app")],
            excluding: "com.example.mactv") { info[$0] }
        #expect(browsers.map(\.bundleID) == ["org.mozilla.firefox", "com.apple.Safari"])
    }
}

@Suite @MainActor
struct WebsitePlayerTests {
    private func withController(_ body: (TVController) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/players-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "MacTV.WebsitePlayerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try body(TVController(library: AppLibrary(folder: folder), browserPreferences: BrowserPreferences(defaults: defaults)))
    }

    @Test
    func listsBuiltInThenBraveThenTheOtherBrowsers() throws {
        try withController { tv in
            tv.browserLookup = {
                [.init(bundleID: "com.apple.Safari", name: "Safari"), .init(bundleID: "com.brave.Browser", name: "Brave Browser")]
            }
            #expect(tv.websitePlayers.map(\.choice) == [.embedded, .brave, .app("com.apple.Safari")])
            #expect(tv.websitePlayers.map(\.name) == ["Built-in", "Brave", "Safari"])
            tv.browserLookup = { [] }
            #expect(tv.websitePlayers.map(\.choice) == [.embedded])
        }
    }

    @Test
    func choosingRejectsBrowsersThatArentInstalled() throws {
        try withController { tv in
            tv.browserLookup = { [.init(bundleID: "com.apple.Safari", name: "Safari")] }
            #expect(!tv.setWebsitePlayer("org.mozilla.firefox"))
            #expect(!tv.setWebsitePlayer("brave"))
            #expect(tv.websitePlayerName == "Built-in")
            #expect(tv.setWebsitePlayer("com.apple.Safari"))
            #expect(tv.websitePlayerName == "Safari")
            // Safari removed later: websites play in Mac TV again.
            tv.browserLookup = { [] }
            #expect(tv.websitePlayerName == "Built-in")
        }
    }

    @Test
    func steppingCyclesThroughTheInstalledBrowsers() throws {
        try withController { tv in
            tv.browserLookup = {
                [.init(bundleID: "org.mozilla.firefox", name: "Firefox"), .init(bundleID: "com.brave.Browser", name: "Brave Browser")]
            }
            var names: [String] = []
            for _ in 0..<3 {
                tv.stepWebsitePlayer()
                names.append(tv.websitePlayerName)
            }
            #expect(names == ["Brave", "Firefox", "Built-in"])
            tv.stepWebsitePlayer(forward: false)
            #expect(tv.websitePlayerName == "Firefox")
            #expect(tv.browserPreferences.choice(for: tv.profile.id) == .app("org.mozilla.firefox"))
        }
    }
}
