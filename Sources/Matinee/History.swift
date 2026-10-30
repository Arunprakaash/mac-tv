import Foundation

/// Something watched in Matinee, shown in the Top Shelf.
struct WatchItem: Codable, Hashable, Identifiable {
    let serviceID: String
    let url: URL
    var title: String?
    var image: URL?
    var progress: Double?
    var date: Date

    var id: URL { url }
}

/// What you've watched, newest first, kept in ~/Library/Application Support/Matinee.
@MainActor
final class WatchHistory: ObservableObject {
    @Published private(set) var items: [WatchItem] = []
    private let file: URL

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Matinee", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([WatchItem].self, from: data) {
            items = saved
        }
    }

    func items(for serviceID: String) -> [WatchItem] {
        items.filter { $0.serviceID == serviceID }
    }

    func record(_ item: WatchItem) {
        // The same title watched again moves to the front instead of repeating.
        items.removeAll {
            $0.serviceID == item.serviceID && ($0.url == item.url || ($0.title != nil && $0.title == item.title))
        }
        items.insert(item, at: 0)
        items = Array(items.prefix(60))
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Reads what's playing from the page. Returns JSON, or null when nothing long is playing.
    static let captureScript = #"""
    (() => {
      const video = [...document.querySelectorAll('video, audio')].find(v => v.duration > 60 && v.currentTime > 5);
      if (!video) return null;
      const meta = name => document.querySelector(`meta[property="${name}"], meta[name="${name}"]`)?.content || '';
      const text = selectors => {
        for (const s of selectors) {
          const t = document.querySelector(s)?.textContent?.trim();
          if (t) return t;
        }
        return '';
      };
      const title = text(['[data-uia="video-title"] h4', '[data-uia="video-title"]', '.atvwebplayersdk-title-text', '[data-testid="player-title"]'])
        || meta('og:title') || document.title;
      let image = document.querySelector('[data-testid="cover-art-image"], ytmusic-player-bar img.image')?.src || meta('og:image');
      const youtube = location.href.match(/[?&]v=([\w-]{11})/);
      if (youtube) image = `https://i.ytimg.com/vi/${youtube[1]}/hqdefault.jpg`;
      return JSON.stringify({ url: location.href, title, image, progress: video.currentTime / video.duration });
    })()
    """#
}
