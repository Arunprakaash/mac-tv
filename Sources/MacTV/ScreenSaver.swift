import AVFoundation
import AppKit
import ImageIO
import SwiftUI

/// What the screen saver shows, when it starts and whether the clock is on top; kept in UserDefaults.
@MainActor
enum ScreenSaverSettings {
    enum Wallpaper: String, CaseIterable {
        case aerials, topShelf, photos, colour

        var title: String {
            switch self {
            case .aerials: "Aerials"
            case .topShelf: "Top Shelf"
            case .photos: "Your Photos"
            case .colour: "Drifting Colour"
            }
        }
    }

    static let delays = [2, 5, 10, 15, 30]

    /// Which live wallpapers Aerials plays: a category's id, or nil for all of them.
    static var aerialCategory: String? {
        get { UserDefaults.standard.string(forKey: "saverAerialCategory") }
        set { UserDefaults.standard.set(newValue, forKey: "saverAerialCategory") }
    }
    /// The pictures the screen saver showing now plays, picked when it starts.
    static var playing: [URL] = []

    static var wallpaper: Wallpaper {
        get {
            UserDefaults.standard.string(forKey: "saverWallpaper").flatMap(Wallpaper.init(rawValue:))
                ?? (Aerials.available ? .aerials : .topShelf)
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "saverWallpaper") }
    }

    static var delayMinutes: Int {
        get { (UserDefaults.standard.object(forKey: "saverDelay") as? Int).flatMap { delays.contains($0) ? $0 : nil } ?? 5 }
        set { UserDefaults.standard.set(newValue, forKey: "saverDelay") }
    }

    static var showClock: Bool {
        get { UserDefaults.standard.object(forKey: "saverClock") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "saverClock") }
    }

    /// The folder Your Photos plays from; the Pictures folder until the user picks another.
    static var photosFolder: URL {
        get {
            UserDefaults.standard.string(forKey: "saverPhotos").map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "saverPhotos") }
    }

    static func step(_ by: Int) {
        let all = Wallpaper.allCases
        let index = all.firstIndex(of: wallpaper) ?? 0
        wallpaper = all[min(max(index + by, 0), all.count - 1)]
    }

    static func stepAerialCategory(_ by: Int, wrap: Bool = false) {
        let choices: [String?] = [nil] + Aerials.categories.map { Optional($0.id) }
        let index = choices.firstIndex { $0 == aerialCategory } ?? 0
        let next = wrap ? (index + by + choices.count) % choices.count : min(max(index + by, 0), choices.count - 1)
        aerialCategory = choices[next]
    }

    static func stepDelay(_ by: Int, wrap: Bool = false) {
        let index = delays.firstIndex(of: delayMinutes) ?? 1
        let next = wrap ? (index + by + delays.count) % delays.count : min(max(index + by, 0), delays.count - 1)
        delayMinutes = delays[next]
    }

    static func choosePhotosFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = photosFolder
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder of photos for the screen saver."
        if panel.runModal() == .OK, let url = panel.url {
            photosFolder = url
            wallpaper = .photos
        }
    }

    /// The pictures a slideshow wallpaper plays, in a fixed shuffled order.
    static func pictures(for wallpaper: Wallpaper) -> [URL] {
        let folder: URL
        switch wallpaper {
        case .topShelf: folder = AppFolder.url.appendingPathComponent("Top Shelf", isDirectory: true)
        case .photos: folder = photosFolder
        case .aerials: return Aerials.films(in: aerialCategory)
        case .colour: return []
        }
        let types: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tiff"]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var generator = SystemRandomNumberGenerator()
        return files.filter { types.contains($0.pathExtension.lowercased()) }.shuffled(using: &generator)
    }
}

/// The screen saver's picture: the chosen wallpaper, falling back to drifting colour when it has nothing to show.
struct ScreenSaverBackdrop: View {
    let wallpaper: ScreenSaverSettings.Wallpaper
    let pictures: [URL]

    var body: some View {
        switch wallpaper {
        case .aerials where !pictures.isEmpty:
            AerialPlayer(films: pictures)
        case .topShelf, .photos:
            if pictures.isEmpty { DriftingColor() } else { Slideshow(files: pictures) }
        default:
            DriftingColor()
        }
    }
}

/// Pictures that slowly zoom and cross-fade, one every few seconds, like Apple TV's photo screen saver.
struct Slideshow: View {
    let files: [URL]
    private static let hold: TimeInterval = 9
    private static let fade: TimeInterval = 1.8
    /// One clock for every slideshow, so redraws never restart it.
    private static let epoch = Date()

    var body: some View {
        // Color.clear sets the size, so a photo wider than the screen fills it instead of widening it.
        Color.clear.overlay {
            frames
        }
        .clipped()
    }

    private var frames: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let elapsed = context.date.timeIntervalSince(Self.epoch)
            let index = Int(elapsed / Self.hold)
            let into = elapsed - Double(index) * Self.hold
            ZStack {
                slide(files[(index + files.count - 1) % files.count], progress: 1 + into / Self.hold)
                slide(files[index % files.count], progress: into / Self.hold)
                    .opacity(min(1, into / Self.fade))
            }
        }
    }

    @ViewBuilder
    private func slide(_ file: URL, progress: Double) -> some View {
        if let image = SlideImages.image(file) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .scaleEffect(1.02 + 0.08 * progress)
        } else {
            Color.black
        }
    }
}

/// Decoded slideshow pictures, scaled down for the TV and kept for the last few files.
@MainActor
enum SlideImages {
    private static var cache: [URL: NSImage] = [:]
    private static var order: [URL] = []

    static func image(_ url: URL) -> NSImage? {
        if let cached = cache[url] { return cached }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 2560]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[url] = image
        order.append(url)
        if order.count > 6 { cache[order.removeFirst()] = nil }
        return image
    }
}

/// A still for each wallpaper choice in Settings.
struct WallpaperThumb: View {
    let wallpaper: ScreenSaverSettings.Wallpaper

    var body: some View {
        // The frame comes from Color.clear, so a wide photo fills its slot instead of widening it.
        Color.clear.overlay {
            ZStack { picture }
        }
        .clipped()
    }

    @ViewBuilder private var picture: some View {
        switch wallpaper {
        case .aerials:
            if let thumb = Aerials.thumbnail(forCategory: ScreenSaverSettings.aerialCategory), let image = SlideImages.image(thumb) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(hex: "#5B7A3A"), Color(hex: "#1E3A2A")], startPoint: .top, endPoint: .bottom)
                Image(systemName: "mountain.2.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.6))
            }
        case .topShelf, .photos:
            if let first = ScreenSaverSettings.pictures(for: wallpaper).first, let image = SlideImages.image(first) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.07)
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.white.opacity(0.6))
            }
        case .colour:
            LinearGradient(colors: [Color(hex: "#4338CA"), Color(hex: "#9D174D"), Color(hex: "#0E7490")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

}

/// Apple's live wallpapers (aerials): the same catalog, thumbnails and downloads System Settings › Wallpaper
/// uses, kept in ~/Library/Application Support/com.apple.wallpaper/aerials. A wallpaper the Mac has downloaded
/// plays from disk; the rest stream from the address in that catalog, as System Settings' previews do.
@MainActor
enum Aerials {
    struct Film {
        let id: String
        let category: String
        let remote: URL?
    }

    struct Category: Identifiable {
        let id: String
        let name: String
        let representative: String?
    }

    private static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.apple.wallpaper/aerials", isDirectory: true)
    /// Where macOS before 26 kept downloaded aerials.
    private static let olderFolder = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true)

    private struct Catalog {
        var films: [Film] = []
        var categories: [Category] = []
    }

    private static let catalog: Catalog = {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest/entries.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Catalog() }
        let strings = localizedStrings()
        let categories = ((json["categories"] as? [[String: Any]]) ?? [])
            .sorted { ($0["preferredOrder"] as? Int ?? 0) < ($1["preferredOrder"] as? Int ?? 0) }
            .compactMap { entry -> Category? in
                guard let id = entry["id"] as? String, let key = entry["localizedNameKey"] as? String else { return nil }
                return Category(id: id, name: strings[key] ?? key.replacingOccurrences(of: "AerialCategory", with: ""),
                                representative: entry["representativeAssetID"] as? String)
            }
        let films = ((json["assets"] as? [[String: Any]]) ?? []).compactMap { entry -> Film? in
            guard let id = entry["id"] as? String, let category = (entry["categories"] as? [String])?.first else { return nil }
            return Film(id: id, category: category, remote: (entry["url-4K-SDR-240FPS"] as? String).flatMap(URL.init(string:)))
        }
        return Catalog(films: films, categories: categories)
    }()

    /// The catalog's names in the user's language, from macOS's own strings bundle.
    private static func localizedStrings() -> [String: String] {
        let file = folder.appendingPathComponent("manifest/TVIdleScreenStrings.bundle/Contents/Resources/Localizable.nocache.loctable")
        guard let data = try? Data(contentsOf: file),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: String]]
        else { return [:] }
        for language in Locale.preferredLanguages {
            let code = language.replacingOccurrences(of: "-", with: "_")
            let base = String(code.split(separator: "_").first ?? "")
            if let strings = table[code] ?? table[base] { return strings }
        }
        return table["en"] ?? [:]
    }

    /// Categories that have at least one wallpaper, in System Settings' order.
    static var categories: [Category] {
        catalog.categories.filter { category in catalog.films.contains { $0.category == category.id } }
    }

    static var available: Bool { !catalog.films.isEmpty || !olderFilms.isEmpty }

    private static func local(_ id: String) -> URL? {
        let file = folder.appendingPathComponent("videos/\(id).mov")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private static let olderFilms: [URL] = {
        guard let walker = FileManager.default.enumerator(at: olderFolder, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "mov" }
    }()

    /// What to play for a category (nil for all): downloaded films first so it starts at once, then streamed ones.
    static func films(in category: String?) -> [URL] {
        let chosen = catalog.films.filter { category == nil || $0.category == category }
        let downloaded = chosen.compactMap { local($0.id) }.shuffled()
        let streamed = chosen.filter { local($0.id) == nil }.compactMap(\.remote).shuffled()
        let films = downloaded + streamed.prefix(24)
        return films.isEmpty ? olderFilms.shuffled() : films
    }

    /// A category's picture (nil for all): its representative wallpaper's thumbnail.
    static func thumbnail(forCategory category: String?) -> URL? {
        let id = category.flatMap { id in catalog.categories.first { $0.id == id }?.representative }
            ?? catalog.categories.first?.representative
        guard let id else { return nil }
        let file = folder.appendingPathComponent("thumbnails/\(id).png")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}
