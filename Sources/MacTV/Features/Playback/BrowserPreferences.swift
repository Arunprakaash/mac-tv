import AppKit
import UniformTypeIdentifiers

/// A website player choice belongs to the Mac TV profile, not the system browser.
enum BrowserChoice: Hashable {
    case embedded, brave
    /// Another browser installed on this Mac, by bundle id.
    case app(String)

    static let braveBundleID = "com.brave.Browser"

    /// Stored values "embedded" and "brave" from earlier versions still load; any other value is a bundle id.
    init?(rawValue: String) {
        switch rawValue {
        case "": return nil
        case "embedded": self = .embedded
        case "brave", Self.braveBundleID: self = .brave
        default: self = .app(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .embedded: "embedded"
        case .brave: "brave"
        case .app(let bundleID): bundleID
        }
    }
}

/// A browser on this Mac that can play websites.
struct InstalledBrowser: Hashable {
    let bundleID: String
    let name: String
}

enum BrowserDiscovery {
    /// The browsers on this Mac that open https links and HTML documents and can open a site as an app.
    static func installed() -> [InstalledBrowser] {
        let workspace = NSWorkspace.shared
        return browsers(httpsHandlers: workspace.urlsForApplications(toOpen: URL(string: "https://example.com")!),
                        htmlHandlers: workspace.urlsForApplications(toOpen: .html),
                        excluding: Bundle.main.bundleIdentifier) { url in
            guard supportsAppMode(url), let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
            return InstalledBrowser(bundleID: id, name: FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: ""))
        }
    }

    /// Chromium browsers ship `app_mode_loader` in their framework's Helpers: what their installed web apps run
    /// on, and what makes `--app` work. Electron apps and other engines (Safari, Firefox) don't have it.
    static func supportsAppMode(_ app: URL, fileManager: FileManager = .default) -> Bool {
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        let names = (try? fileManager.contentsOfDirectory(atPath: frameworks.path)) ?? []
        return names.contains { name in
            name.hasSuffix(".framework")
                && fileManager.fileExists(atPath: frameworks.appendingPathComponent(name).appendingPathComponent("Helpers/app_mode_loader").path)
        }
    }

    /// Apps in both lists, one per bundle id, without `excluding` (Mac TV itself), sorted by name.
    static func browsers(httpsHandlers: [URL], htmlHandlers: [URL], excluding: String?,
                         describe: (URL) -> InstalledBrowser?) -> [InstalledBrowser] {
        let html = Set(htmlHandlers.map(\.standardizedFileURL))
        var seen = Set<String>()
        return httpsHandlers.filter { html.contains($0.standardizedFileURL) }
            .compactMap(describe)
            .filter { $0.bundleID != excluding && seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct BrowserPreferences {
    private let defaults: UserDefaults
    private let key = "websitePlayerByProfile"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The built-in player until someone chooses a browser: installing one never switches a profile on its own.
    func choice(for profileID: String) -> BrowserChoice {
        let choices = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return choices[profileID].flatMap(BrowserChoice.init(rawValue:)) ?? .embedded
    }

    func setChoice(_ choice: BrowserChoice, for profileID: String) {
        var choices = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        choices[profileID] = choice.rawValue
        defaults.set(choices, forKey: key)
    }
}
