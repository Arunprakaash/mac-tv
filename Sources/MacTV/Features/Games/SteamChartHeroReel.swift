import AppKit
import SwiftUI

/// Best of Year › Controller hero reel for Steam Big Picture's Top Shelf.
/// Chart year N is kept through calendar N+1; from N+2 we look for year N+1. Images load lazily.
@MainActor
final class SteamChartHeroReel: ObservableObject {
    static let shared = SteamChartHeroReel()

    @Published private(set) var image: NSImage?
    @Published private(set) var appID = ""
    @Published private(set) var title = ""

    private var order: [String] = []
    /// Chart order as returned by Steam (for disk), separate from the shuffled playback `order`.
    private var chartIDs: [String] = []
    private var index = 0
    private var timer: Timer?
    private var cache: [String: NSImage] = [:]
    private var names: [String: String] = [:]
    private var chartYear = 0
    private var started = false

    private static let hold: TimeInterval = 8
    private static let limit = 100

    private struct Saved: Codable {
        let year: Int
        let appIDs: [String]
        var names: [String: String]?
    }

    private var folder: URL { AppFolder.url.appendingPathComponent("Steam Chart Heroes", isDirectory: true) }
    private var listFile: URL { folder.appendingPathComponent("bestofyear-controller.json") }

    private init() {}

    func start(animate: Bool) {
        if !started {
            started = true
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            clearLegacyCaches()
            let calendarYear = Calendar(identifier: .gregorian).component(.year, from: Date())
            if let saved = load(), !saved.appIDs.isEmpty {
                chartYear = saved.year
                chartIDs = saved.appIDs
                names = saved.names ?? [:]
                apply(saved.appIDs, shuffle: true)
                // Chart 2025 stays through 2026; only in 2027 do we look for 2026.
                if SteamLibrary.shouldRefreshChart(savedYear: saved.year, calendarYear: calendarYear) {
                    Task { await refresh(afterYear: saved.year) }
                }
            } else {
                // Seed Top 10 so the first session isn’t blank while charts load (or offline).
                names = Dictionary(uniqueKeysWithValues: SteamLibrary.chartBootstrapGames.map { ($0.appID, $0.name) })
                apply(SteamLibrary.chartBootstrapGames.map(\.appID), shuffle: true)
                Task { await refresh() }
            }
        }
        if image == nil {
            Task { await show(at: index); prefetch(around: index) }
        }
        guard animate, order.count > 1, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.hold, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
    }

    private func refresh(afterYear: Int? = nil) async {
        let chart = await SteamLibrary.bestOfYearControllerChart(limit: Self.limit, afterYear: afterYear)
        guard !chart.appIDs.isEmpty else { return }
        // Keep the on-disk year unless Steam returned a newer chart year.
        if chart.year <= chartYear, !order.isEmpty { return }
        chartYear = chart.year
        chartIDs = chart.appIDs
        names = names.filter { chart.appIDs.contains($0.key) }
        prune(keeping: Set(chart.appIDs))
        persist(Saved(year: chart.year, appIDs: chart.appIDs, names: names))
        apply(chart.appIDs, shuffle: true)
        await show(at: 0)
        prefetch(around: 0)
    }

    private func prune(keeping ids: Set<String>) {
        cache = cache.filter { ids.contains($0.key) }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "jpg" {
            let id = file.deletingPathExtension().lastPathComponent
            if !ids.contains(id) { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func apply(_ ids: [String], shuffle: Bool) {
        order = shuffle ? ids.shuffled() : ids
        if order.isEmpty { return }
        index %= order.count
    }

    private func advance() {
        guard !order.isEmpty else { return }
        index = (index + 1) % order.count
        Task { await show(at: index); prefetch(around: index) }
    }

    private func show(at i: Int) async {
        guard !order.isEmpty else { return }
        for offset in 0..<order.count {
            let id = order[(i + offset) % order.count]
            if let picture = await image(for: id) {
                index = (i + offset) % order.count
                let label = await name(for: id)
                withAnimation(.easeInOut(duration: 1.1)) {
                    appID = id
                    title = label
                    image = picture
                }
                return
            }
        }
    }

    private func prefetch(around i: Int) {
        guard order.count > 1 else { return }
        let next = order[(i + 1) % order.count]
        Task {
            _ = await image(for: next)
            _ = await name(for: next)
        }
    }

    private func name(for id: String) async -> String {
        if let cached = names[id], !cached.isEmpty { return cached }
        guard let fetched = await SteamLibrary.storeName(for: id) else { return "" }
        names[id] = fetched
        if chartYear > 0, !chartIDs.isEmpty {
            persist(Saved(year: chartYear, appIDs: chartIDs, names: names))
        }
        return fetched
    }

    private func image(for id: String) async -> NSImage? {
        if let cached = cache[id] { return cached }
        let file = folder.appendingPathComponent("\(id).jpg")
        if let picture = NSImage(contentsOf: file), picture.size.width > 0 {
            cache[id] = picture
            return picture
        }
        await SteamLibrary.ensureLibraryHeroFile(appID: id, at: file)
        guard let picture = NSImage(contentsOf: file), picture.size.width > 0 else { return nil }
        cache[id] = picture
        return picture
    }

    private func load() -> Saved? {
        (try? Data(contentsOf: listFile)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }

    private func persist(_ saved: Saved) {
        Log.app.attempt("Saving Steam chart heroes") {
            try JSONEncoder().encode(saved).write(to: listFile, options: .atomic)
        }
    }

    /// Drop older list filenames / folders from earlier iterations of this feature.
    private func clearLegacyCaches() {
        try? FileManager.default.removeItem(at: AppFolder.url.appendingPathComponent("Glimmer Heroes", isDirectory: true))
        for name in ["charts.json", "bestofyear-tab5.json", "bestofyear-tab5-100.json"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
