import SwiftUI

/// An empty language list means all languages. Region is an ISO country code, or empty for worldwide.
/// Out of the box: worldwide (plus India and the US), in languages people here watch.
struct ShelfPreferences: Codable, Equatable {
    var region = ""
    var languages: [String] = ["Bengali", "English", "Hindi", "Japanese", "Kannada", "Korean", "Malayalam",
                               "Marathi", "Spanish", "Tamil", "Telugu"]
    static let regions: [(code: String, name: String)] = [("", "Worldwide"), ("GB", "United Kingdom"), ("IN", "India"), ("US", "United States"), ("CA", "Canada"), ("AU", "Australia")]
    static let languageOptions = ["English", "Hindi", "Tamil", "Telugu", "Malayalam", "Kannada", "Bengali", "Marathi", "Japanese", "Korean", "Spanish", "French"]
    func includes(language: String?) -> Bool {
        languages.isEmpty || language.map { languages.contains($0) } == true
    }
    static func load() -> ShelfPreferences {
        guard let data = UserDefaults.standard.data(forKey: "topShelfPreferences"),
              let value = try? JSONDecoder().decode(ShelfPreferences.self, from: data) else { return ShelfPreferences() }
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
        let feed = TopShelfFeed.shared
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
    @ObservedObject private var feed = TopShelfFeed.shared
    @Environment(\.canvasSize) private var canvas
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let panel = tv.topShelfPreferences ?? TopShelfPreferencesPanel()
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Top Shelf").font(.system(size: 48, weight: .heavy))
                Spacer()
                Button("Done") { tv.topShelfPreferences = nil }.buttonStyle(.plain).font(.system(size: 24, weight: .semibold))
            }
            Text("Choose a TV schedule region and languages. Music charts use the selected region, or this Mac’s region for Worldwide. Artwork may contain its original language.")
                .font(.system(size: 22)).foregroundStyle(.white.opacity(0.7))
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
                .onChange(of: panel.row) { _, row in withAnimation(reduceMotion ? nil : Motion.focus) { proxy.scrollTo(row, anchor: .center) } }
            }
            Text("↑ ↓ Choose    ← → Change    OK Select    Back Close · Changes refresh the shelf")
                .font(.system(size: 20)).foregroundStyle(.white.opacity(0.65))
        }
        .padding(48).frame(width: 1100, alignment: .leading)
        .tvGlass(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white).frame(width: canvas.width, height: canvas.height)
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
