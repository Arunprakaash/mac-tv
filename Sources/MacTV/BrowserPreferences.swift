import AppKit

/// A website player choice belongs to the Mac TV profile, not the system browser.
enum BrowserChoice: String {
    case embedded, brave
}

@MainActor
struct BrowserPreferences {
    private let defaults: UserDefaults
    private let key = "websitePlayerByProfile"
    private let braveAvailable: () -> Bool

    init(defaults: UserDefaults = .standard,
         braveAvailable: @escaping () -> Bool = {
             NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.brave.Browser") != nil
         }) {
        self.defaults = defaults
        self.braveAvailable = braveAvailable
    }

    func choice(for profileID: String) -> BrowserChoice {
        let choices = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return choices[profileID].flatMap(BrowserChoice.init(rawValue:)) ?? (braveAvailable() ? .brave : .embedded)
    }

    func setChoice(_ choice: BrowserChoice, for profileID: String) {
        var choices = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        choices[profileID] = choice.rawValue
        defaults.set(choices, forKey: key)
    }
}
