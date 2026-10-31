import SwiftUI

/// Each streaming app's latest shows for the Top Shelf, like Apple TV's: series with new episodes
/// on that app in the past two weeks, most popular first, from TVmaze's public streaming schedule
/// (tvmaze.com, CC BY-SA, no key). Refreshed once a day in the background; the list and the images
/// are kept in ~/Library/Application Support/Mac TV/Top Shelf. Nothing here comes from what you watch.
@MainActor
final class TopShelfFeed: ObservableObject {
    struct Show: Codable, Hashable, Identifiable {
        let id: Int
        let name: String
        let image: URL
    }

    private struct Saved: Codable {
        let fetched: Date
        let services: [String: [Show]]
    }

    static let shared = TopShelfFeed()

    /// TVmaze's names for each app's streaming service.
    private static let channels = ["Netflix": "netflix", "Prime Video": "prime", "Amazon Prime Video": "prime",
                                   "Apple TV": "appletv", "Apple TV+": "appletv",
                                   "JioHotstar": "hotstar", "Disney+ Hotstar": "hotstar", "Hotstar": "hotstar"]
    /// Series only: sports, talk shows, news and reality TV make poor Top Shelf art.
    private static let kinds: Set<String> = ["Scripted", "Animation", "Documentary"]
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

    func shows(for serviceID: String) -> [Show] { ready[serviceID] ?? [] }

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
                          let id = show["id"] as? Int, let name = show["name"] as? String else { continue }
                    found[app, default: [:]][id] = (name, show["weight"] as? Int ?? 0)
                }
            }
        }
        guard !found.isEmpty else { return }  // Offline: keep what we have.
        var services: [String: [Show]] = [:]
        for (app, shows) in found {
            var picked: [Show] = []
            for (id, show) in shows.sorted(by: { $0.value.weight > $1.value.weight }) {
                guard let image = await Self.background(for: id) else { continue }
                picked.append(Show(id: id, name: show.name, image: image))
                if picked.count == Self.perApp { break }
            }
            services[app] = picked
        }
        if let data = try? JSONEncoder().encode(Saved(fetched: Date(), services: services)) {
            try? data.write(to: listFile, options: .atomic)
        }
        use(services)
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
