import SwiftUI
import Vision

/// Each streaming app's latest shows for the Top Shelf, like Apple TV's: series with new episodes
/// on that app in the past two weeks, most popular first, from TVmaze's public streaming schedule
/// (tvmaze.com, CC BY-SA, no key). Music apps get this week's most-played albums in your country, from
/// Apple's public charts (no key). Refreshed once a day in the background; the list and the images
/// are kept in ~/Library/Application Support/Mac TV/Top Shelf. Nothing here comes from what you watch.
@MainActor
final class TopShelfFeed: ObservableObject {
    struct Show: Codable, Hashable, Identifiable {
        let id: Int
        let name: String
        let image: URL
        /// A square album cover rather than wide show art.
        var square = false
    }

    private struct Saved: Codable {
        let fetched: Date
        let services: [String: [Show]]
    }

    static let shared = TopShelfFeed()

    /// TVmaze's names for each app's streaming service.
    private static let channels = ["Netflix": "netflix", "Prime Video": "prime", "Amazon Prime Video": "prime",
                                   "Apple TV": "appletv", "Apple TV+": "appletv",
                                   "JioHotstar": "hotstar", "Disney+ Hotstar": "hotstar", "Hotstar": "hotstar",
                                   "YouTube": "youtube"]
    /// Music apps show the week's top albums.
    private static let musicApps = ["spotify", "ytmusic"]
    /// Series only: sports, talk shows, news and reality TV make poor Top Shelf art.
    private static let kinds: Set<String> = ["Scripted", "Animation", "Documentary"]
    /// Some shows' art carries their title in their own script; keep to languages people here watch.
    private static let languages: Set<String> = ["English", "Hindi", "Tamil", "Telugu", "Malayalam", "Kannada",
                                                 "Bengali", "Marathi", "Japanese", "Korean", "Spanish"]
    private static let perApp = 8

    /// Shows whose image is ready, by app id.
    @Published private(set) var ready: [String: [Show]] = [:]
    /// Moves on every few seconds: which show each app's Top Shelf is on.
    @Published private(set) var turn = 0
    /// When the current show came up, for its slow drift.
    private(set) var turnStarted = Date()
    private var clock: Timer?
    private(set) var images: [Int: NSImage] = [:]
    private var lists: [String: [Show]] = [:]
    private let folder = AppFolder.url.appendingPathComponent("Top Shelf", isDirectory: true)
    private var listFile: URL { folder.appendingPathComponent("shows.json") }
    private var started = false

    private init() {}

    /// An app's own shows; apps with none (websites, Mac apps, games) get the top of every app's.
    func shows(for serviceID: String) -> [Show] {
        if let own = ready[serviceID], !own.isEmpty { return own }
        return mix
    }

    /// Every app's most popular shows taken in turn: the first of each, then the second of each…
    private var mix: [Show] {
        let lists = ready.keys.sorted().compactMap { ready[$0]?.filter { !$0.square } }.filter { !$0.isEmpty }
        let longest = lists.map(\.count).max() ?? 0
        var seen = Set<Int>()
        return (0..<longest).flatMap { rank in lists.compactMap { rank < $0.count ? $0[rank] : nil } }
            .filter { seen.insert($0.id).inserted }
    }

    /// Shows the last list straight away, then fetches a fresh one if it's a day old.
    func start() {
        guard !started else { return }
        started = true
        clock = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.turnStarted = Date()
                withAnimation(.easeInOut(duration: 1.4)) { self.turn += 1 }
            }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = (try? Data(contentsOf: listFile)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        if let saved { use(saved.services) }
        if saved.map({ Date().timeIntervalSince($0.fetched) > 20 * 3600 }) ?? true {
            Task { await refresh() }
        }
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// Asks TVmaze for the past two weeks of streaming episodes, keeps each app's most popular series,
    /// and finds a wide background picture for each.
    func refresh() async {
        var found: [String: [Int: (name: String, weight: Int)]] = [:]
        let today = Date()
        for day in 0..<14 {
            let date = ISO8601DateFormatter.string(from: today.addingTimeInterval(Double(-day) * 86400), timeZone: .current,
                                                   formatOptions: [.withFullDate])
            for region in ["", "&country=IN", "&country=US"] {
                guard let episodes = await Self.json("https://api.tvmaze.com/schedule/web?date=\(date)\(region)") as? [[String: Any]] else { continue }
                for episode in episodes {
                    guard let show = (episode["_embedded"] as? [String: Any])?["show"] as? [String: Any],
                          let channel = (show["webChannel"] as? [String: Any])?["name"] as? String,
                          let app = Self.channels[channel], let kind = show["type"] as? String, Self.kinds.contains(kind),
                          let language = show["language"] as? String, Self.languages.contains(language),
                          let id = show["id"] as? Int, let name = show["name"] as? String else { continue }
                    found[app, default: [:]][id] = (name, show["weight"] as? Int ?? 0)
                }
            }
        }
        guard !found.isEmpty else { return }  // Offline: keep what we have.
        // An app whose fetch comes back empty keeps yesterday's list.
        var services = lists
        for (app, shows) in found {
            var picked: [Show] = []
            for (id, show) in shows.sorted(by: { $0.value.weight > $1.value.weight }) {
                guard let image = await Self.background(for: id),
                      await Self.download(image, to: folder.appendingPathComponent("\(id).jpg")) else { continue }
                picked.append(Show(id: id, name: show.name, image: image))
                if picked.count == Self.perApp { break }
            }
            if !picked.isEmpty { services[app] = picked }
        }
        let albums = await Self.topAlbums()
        if !albums.isEmpty {
            // Both music apps show the chart, starting at different places.
            services["spotify"] = albums
            services["ytmusic"] = Array(albums.dropFirst(albums.count / 2) + albums.prefix(albums.count / 2))
        }
        if let data = try? JSONEncoder().encode(Saved(fetched: Date(), services: services)) {
            try? data.write(to: listFile, options: .atomic)
        }
        use(services)
    }

    /// This week's most-played albums in this Mac's country, from Apple's public charts.
    private static func topAlbums() async -> [Show] {
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        for country in [region, "us"] {
            guard let feed = (await json("https://rss.marketingtools.apple.com/api/v2/\(country)/music/most-played/12/albums.json")
                                as? [String: Any])?["feed"] as? [String: Any],
                  let results = feed["results"] as? [[String: Any]], !results.isEmpty else { continue }
            return results.compactMap { album in
                guard let id = (album["id"] as? String).flatMap(Int.init), let name = album["name"] as? String,
                      let art = album["artworkUrl100"] as? String,
                      let url = URL(string: art.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")) else { return nil }
                return Show(id: id, name: name, image: url, square: true)
            }
        }
        return []
    }

    /// A show's widest landscape background picture, at least 1280 wide.
    private static func background(for id: Int) async -> URL? {
        guard let images = await json("https://api.tvmaze.com/shows/\(id)/images") as? [[String: Any]] else { return nil }
        let wide = images.compactMap { image -> (width: Int, url: String)? in
            guard image["type"] as? String == "background",
                  let original = (image["resolutions"] as? [String: Any])?["original"] as? [String: Any],
                  let width = original["width"] as? Int, let height = original["height"] as? Int, let url = original["url"] as? String,
                  width >= 1280, Double(width) / Double(max(height, 1)) >= 1.5 else { return nil }
            return (width, url)
        }
        return wide.max { $0.width < $1.width }.flatMap { URL(string: $0.url) }
    }

    /// Saves a show's picture to the cache, unless it carries writing in a script other than Latin:
    /// a title in a language most people here can't read looks like a mistake.
    private nonisolated static func download(_ url: URL, to file: URL) async -> Bool {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        guard await !Task.detached(operation: { hasForeignText(data) }).value else { return false }
        try? data.write(to: file, options: .atomic)
        return true
    }

    private nonisolated static func hasForeignText(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let request = VNRecognizeTextRequest()
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).contains { observation in
            guard let text = observation.topCandidates(1).first, text.confidence >= 0.5 else { return false }
            let latin = { (letter: Unicode.Scalar) in letter.value < 0x250 || (0x1E00...0x1EFF).contains(letter.value) }
            return text.string.unicodeScalars.filter { $0.properties.isAlphabetic && !latin($0) }.count >= 3
        }
    }

    /// TVmaze allows about 20 requests every 10 seconds, so requests are paced.
    private static func json(_ address: String) async -> Any? {
        try? await Task.sleep(for: .milliseconds(550))
        guard let url = URL(string: address), let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Shows a list: cached pictures at once, the rest as they download.
    private func use(_ services: [String: [Show]]) {
        lists = services
        ready = [:]
        for (serviceID, shows) in services {
            for show in shows {
                let file = folder.appendingPathComponent("\(show.id).jpg")
                if let image = images[show.id] ?? NSImage(contentsOf: file) {
                    add(show, image, to: serviceID)
                    continue
                }
                Task {
                    guard let (data, response) = try? await URLSession.shared.data(from: show.image),
                          (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { return }
                    try? data.write(to: file, options: .atomic)
                    add(show, image, to: serviceID)
                }
            }
        }
    }

    private func add(_ show: Show, _ image: NSImage, to serviceID: String) {
        images[show.id] = image
        // Keep the list's order (most popular first), whatever order the images arrive in.
        let order = lists[serviceID] ?? []
        let have = Set((ready[serviceID] ?? []).map(\.id)).union([show.id])
        ready[serviceID] = order.filter { have.contains($0.id) }
    }
}

/// A show's artwork, full bleed, drifting slowly the way Apple TV's Top Shelf does.
struct ShowBackdrop: View {
    let image: NSImage
    let since: Date
    @Environment(\.canvasSize) private var canvas
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            picture(progress: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                picture(progress: min(1, context.date.timeIntervalSince(since) / 10))
            }
        }
    }

    private func picture(progress: Double) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: canvas.width, height: canvas.height)
            .scaleEffect(1 + 0.06 * progress)
            .offset(x: -18 * progress)
            .clipped()
    }
}

/// An album, the way Apple Music shows one on Apple TV: the cover large on the right, over its own
/// colours blurred across the screen.
struct AlbumBackdrop: View {
    let image: NSImage
    let since: Date
    @Environment(\.canvasSize) private var canvas
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: canvas.width, height: canvas.height)
                .blur(radius: 80)
                .saturation(1.3)
                .overlay(Color.black.opacity(0.35))
                .clipped()
            if reduceMotion {
                cover(progress: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    cover(progress: min(1, context.date.timeIntervalSince(since) / 10))
                }
            }
        }
        .frame(width: canvas.width, height: canvas.height)
    }

    private func cover(progress: Double) -> some View {
        // Square album covers, or tall movie posters.
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        return Image(nsImage: image)
            .resizable()
            .aspectRatio(aspect, contentMode: .fit)
            .frame(width: aspect >= 1 ? 560 : 640 * aspect, height: aspect >= 1 ? 560 / aspect : 640)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
            .scaleEffect(1 + 0.03 * progress)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 150)
            .padding(.trailing, 150)
    }
}
