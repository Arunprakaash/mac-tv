import SwiftUI

/// An empty language list means all languages. Region is an ISO country code, or empty for worldwide.
/// Out of the box: worldwide (plus India and the US), in languages people here watch.
struct ShelfPreferences: Codable, Equatable {
    var region = ""
    var languages: [String] = ["Bengali", "Dutch", "English", "French", "German", "Hindi", "Italian",
                               "Japanese", "Kannada", "Korean", "Malayalam", "Marathi", "Portuguese",
                               "Spanish", "Tamil", "Telugu"]
    static let regions: [(code: String, name: String)] = [
        ("", "Worldwide"), ("DE", "Germany"), ("AT", "Austria"), ("CH", "Switzerland"),
        ("FR", "France"), ("GB", "United Kingdom"), ("IN", "India"), ("US", "United States"),
        ("CA", "Canada"), ("AU", "Australia"), ("JP", "Japan"), ("BR", "Brazil"), ("IT", "Italy"),
        ("NL", "Netherlands"),
    ]
    static let languageOptions = ["English", "German", "French", "Dutch", "Italian", "Portuguese",
                                  "Hindi", "Tamil", "Telugu", "Malayalam", "Kannada",
                                  "Bengali", "Marathi", "Japanese", "Korean", "Spanish"]
    /// Languages added for the Suggested apps' own shows. Older choices get them once, so a language
    /// someone turns off afterwards stays off.
    private static let addedLanguages = ["Dutch", "French", "German", "Italian", "Portuguese"]
    private static let addedLanguagesKey = "topShelfAddedLanguages"
    func includes(language: String?) -> Bool {
        languages.isEmpty || language.map { languages.contains($0) } == true
    }
    static func load() -> ShelfPreferences {
        let addedBefore = UserDefaults.standard.bool(forKey: addedLanguagesKey)
        // Defaults already have them, so a first choice made from the defaults never gets them back.
        UserDefaults.standard.set(true, forKey: addedLanguagesKey)
        guard let data = UserDefaults.standard.data(forKey: "topShelfPreferences"),
              var value = try? JSONDecoder().decode(ShelfPreferences.self, from: data) else { return ShelfPreferences() }
        guard !addedBefore else { return value }
        let missing = addedLanguages.filter { !value.languages.contains($0) }
        if !value.languages.isEmpty, !missing.isEmpty {
            value.languages = (value.languages + missing).sorted()
            value.save()
        }
        return value
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "topShelfPreferences") }
    }
}

enum ShelfSearch {
    static func url(serviceID: String, query: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "https"
        switch serviceID {
        case "netflix": parts.host = "www.netflix.com"; parts.path = "/search"; parts.queryItems = [URLQueryItem(name: "q", value: query)]
        case "youtube": parts.host = "www.youtube.com"; parts.path = "/results"; parts.queryItems = [URLQueryItem(name: "search_query", value: query)]
        case "prime": parts.host = "www.primevideo.com"; parts.path = "/search"; parts.queryItems = [URLQueryItem(name: "phrase", value: query)]
        case "ytmusic": parts.host = "music.youtube.com"; parts.path = "/search"; parts.queryItems = [URLQueryItem(name: "q", value: query)]
        case "spotify":
            parts.host = "open.spotify.com"
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            parts.percentEncodedPath = "/search/" + encoded
        default: return nil
        }
        return parts.url
    }
}

struct TopShelfPreferencesPanel: Equatable {
    var row = 0
}

extension TVController {
    func openTopShelfPreferences() { topShelfPreferences = TopShelfPreferencesPanel() }

    func handleTopShelfPreferences(_ command: RemoteCommand) {
        guard var panel = topShelfPreferences else { return }
        let last = ShelfPreferences.languageOptions.count + 1
        switch command {
        case .back: topShelfPreferences = nil; return
        case .move(.up): panel.row = max(0, panel.row - 1)
        case .move(.down): panel.row = min(last, panel.row + 1)
        case .move(.left): changeTopShelfPreference(row: panel.row, direction: -1); return
        case .move(.right): changeTopShelfPreference(row: panel.row, direction: 1); return
        case .select: changeTopShelfPreference(row: panel.row, direction: 1); return
        default: return
        }
        topShelfPreferences = panel
    }

    func changeTopShelfPreference(row: Int, direction: Int) {
        guard topShelfPreferences != nil else { return }
        topShelfPreferences?.row = row
        let feed = topShelf
        var value = feed.preferences
        if row == 0 {
            let regions = ShelfPreferences.regions
            let current = regions.firstIndex { $0.code == value.region } ?? 0
            value.region = regions[(current + direction + regions.count) % regions.count].code
        } else if row == 1 {
            value.languages = []
        } else if ShelfPreferences.languageOptions.indices.contains(row - 2) {
            let language = ShelfPreferences.languageOptions[row - 2]
            if value.languages.contains(language) { value.languages.removeAll { $0 == language } }
            else { value.languages.append(language); value.languages.sort() }
        }
        feed.updatePreferences(value)
    }
}

struct TopShelfPreferencesSheet: View {
    @ObservedObject var tv: TVController
    @ObservedObject private var feed: TopShelfFeed
    @Environment(\.canvasSize) private var canvas
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tv: TVController) {
        _tv = ObservedObject(wrappedValue: tv)
        _feed = ObservedObject(wrappedValue: tv.topShelf)
    }

    var body: some View {
        let panel = tv.topShelfPreferences ?? TopShelfPreferencesPanel()
        VStack(alignment: .leading, spacing: 16) {
            Text("Top Shelf").font(.tv(.title3, emphasized: true))
            Text("Choose a TV schedule region and languages. Music charts use the selected region, or this Mac’s region for Worldwide. Artwork may contain its original language.")
                .font(.tv(.caption1)).foregroundStyle(.white.opacity(0.7))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        preferenceRow(0, "Schedule region", ShelfPreferences.regions.first { $0.code == feed.preferences.region }?.name ?? "Worldwide", panel)
                        preferenceRow(1, "All languages", feed.preferences.languages.isEmpty ? "On" : "Off", panel)
                        ForEach(Array(ShelfPreferences.languageOptions.enumerated()), id: \.offset) { index, language in
                            preferenceRow(index + 2, language, feed.preferences.languages.contains(language) ? "On" : "Off", panel)
                        }
                    }.padding(8)
                }
                .frame(height: min(600, max(280, canvas.height - 430)))
                .onAppear { proxy.scrollTo(panel.row, anchor: .center) }
                .onChange(of: panel.row) { _, row in withAnimation(reduceMotion ? nil : Motion.navigate) { proxy.scrollTo(row, anchor: .center) } }
            }
            InputHintsBar(tv: tv, set: topShelfHints(panel), note: "Changes refresh the shelf")
        }
        .padding(48).frame(width: 1100, alignment: .leading)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white).frame(width: canvas.width, height: canvas.height)
    }

    private func topShelfHints(_ panel: TopShelfPreferencesPanel) -> HintSet {
        if panel.row == 0 {
            .custom([.moveVertical("Choose"), .moveHorizontal("Change"), .back("Close")])
        } else {
            // Language on/off: ←→ and OK both flip — Toggle only.
            .custom([.moveVertical("Choose"), .select("Toggle"), .back("Close")])
        }
    }

    private func preferenceRow(_ row: Int, _ title: String, _ detail: String, _ panel: TopShelfPreferencesPanel) -> some View {
        let focused = panel.row == row
        return Button { tv.changeTopShelfPreference(row: row, direction: 1) } label: {
            HStack { Text(title); Spacer(); Text(detail); if row == 0 { Image(systemName: "chevron.left.chevron.right") } }
                .font(.system(size: 25, weight: .semibold)).padding(.horizontal, 24).frame(height: 58)
                .foregroundStyle(focused ? .black : .white)
                .background(focused ? .white : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).id(row)
    }
}
