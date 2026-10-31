import AppKit

/// ~/Library/Application Support/Mac TV, where history, added apps and their icons live.
/// Data from the app's earlier name ("Matinee") moves over on first run.
enum AppFolder {
    static let url: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Mac TV", isDirectory: true)
        let earlier = support.appendingPathComponent("Matinee", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path), FileManager.default.fileExists(atPath: earlier.path) {
            try? FileManager.default.moveItem(at: earlier, to: folder)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
}

/// An app the user added: a website, or a Mac app.
struct AddedApp: Codable, Hashable {
    let id: String
    var name: String
    var url: URL?
    var bundleID: String?
    /// The icon's brand colour, found once the icon arrives; tints its Top Shelf.
    var accent: String?
}

/// The home screen's apps: the built-in catalog minus any the user removed, plus the apps they
/// added, then Settings. Kept in ~/Library/Application Support/Mac TV/apps.json.
@MainActor
final class AppLibrary {
    private struct Saved: Codable {
        var added: [AddedApp] = []
        var hidden: Set<String> = []
    }

    private var saved = Saved()
    private let file: URL
    let iconsFolder: URL

    init() {
        let folder = AppFolder.url
        iconsFolder = folder.appendingPathComponent("Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: iconsFolder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("apps.json")
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = decoded
        }
    }

    var hasHiddenBuiltIns: Bool { !saved.hidden.isEmpty }

    func services() -> [Service] {
        let fixed: Set<Service.Kind> = [.addApp, .settings]
        let builtIn = Catalog.services.filter { !fixed.contains($0.kind) && !saved.hidden.contains($0.id) }
        let added = saved.added.compactMap(service(for:))
        let tail = Catalog.services.filter { fixed.contains($0.kind) }
        return (builtIn + added).filter(\.isInstalled) + tail
    }

    func iconFile(for id: String) -> URL { iconsFolder.appendingPathComponent("\(id).png") }

    private func service(for app: AddedApp) -> Service? {
        let kind: Service.Kind
        if let url = app.url { kind = .web(url) } else if let bundleID = app.bundleID { kind = .app(bundleID: bundleID) } else { return nil }
        let icon = iconFile(for: app.id)
        let accent = app.accent ?? "#8E8E93"
        return Service(id: app.id, name: app.name, kind: kind,
                       iconFile: FileManager.default.fileExists(atPath: icon.path) ? icon : nil,
                       accent: accent, deep: Self.darkened(accent))
    }

    @discardableResult
    func add(name: String, url: URL?, bundleID: String?) -> AddedApp {
        let base = name.lowercased().filter { $0.isLetter || $0.isNumber }
        var id = "user-" + (base.isEmpty ? "app" : base)
        let taken = Set(Catalog.services.map(\.id) + saved.added.map(\.id))
        if taken.contains(id) { id += "-\(Int.random(in: 1000...9999))" }
        let app = AddedApp(id: id, name: name, url: url, bundleID: bundleID)
        saved.added.append(app)
        save()
        return app
    }

    func setIcon(_ png: Data, accent: String?, for id: String) {
        try? png.write(to: iconFile(for: id), options: .atomic)
        if let index = saved.added.firstIndex(where: { $0.id == id }) {
            saved.added[index].accent = accent
            save()
        }
    }

    /// Removes an added app, or hides a built-in one.
    func remove(_ id: String) {
        if let index = saved.added.firstIndex(where: { $0.id == id }) {
            saved.added.remove(at: index)
            try? FileManager.default.removeItem(at: iconFile(for: id))
        } else if Catalog.services.contains(where: { $0.id == id && $0.kind != .settings && $0.kind != .addApp }) {
            saved.hidden.insert(id)
        }
        save()
    }

    /// Brings back any built-in apps the user removed.
    func restoreBuiltIns() {
        saved.hidden = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
    }

    private static func darkened(_ hex: String) -> String {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        let r = Double((value >> 16) & 0xFF) * 0.18, g = Double((value >> 8) & 0xFF) * 0.18, b = Double(value & 0xFF) * 0.18
        return String(format: "#%02X%02X%02X", Int(r), Int(g), Int(b))
    }
}

/// Finds an official-looking square icon for an app the user adds.
enum IconFinder {
    /// For a website: its App Store app's icon (crisp, 1024 px) when the name matches one,
    /// else the largest home-screen icon the site publishes.
    static func icon(forSite site: URL, name: String) async -> Data? {
        if let data = await appStoreIcon(named: name) { return data }
        return await siteIcon(site)
    }

    /// A Mac app's own icon.
    @MainActor
    static func icon(forAppAt path: String) -> Data? {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 512, height: 512)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func appStoreIcon(named name: String) async -> Data? {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return nil }
        var query = URLComponents(string: "https://itunes.apple.com/search")!
        query.queryItems = [.init(name: "term", value: name), .init(name: "entity", value: "software"),
                            .init(name: "limit", value: "8"),
                            .init(name: "country", value: Locale.current.region?.identifier ?? "US")]
        guard let url = query.url, let data = await fetch(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        // Only trust a result whose name actually matches, e.g. "Crunchyroll" or "Crunchyroll: Anime".
        let match = results.first { result in
            let title = normalized(result["trackName"] as? String ?? "")
            return title == wanted || title.hasPrefix(wanted) || (wanted.count > 3 && wanted.hasPrefix(title) && title.count > 3)
        }
        guard let artwork = match?["artworkUrl512"] as? String,
              let large = URL(string: artwork.replacingOccurrences(of: "512x512bb.jpg", with: "1024x1024bb.png"))
        else { return nil }
        return await fetchImage(large)
    }

    private static func siteIcon(_ site: URL) async -> Data? {
        var candidates: [(url: URL, size: Int)] = []
        if let page = await fetch(site), let html = String(data: page, encoding: .utf8) ?? String(data: page, encoding: .isoLatin1) {
            for tag in matches(of: "<link\\b[^>]*>", in: html) {
                guard let rel = attribute("rel", in: tag)?.lowercased(), let href = attribute("href", in: tag),
                      let url = URL(string: href, relativeTo: site)?.absoluteURL else { continue }
                if rel.contains("manifest") {
                    candidates += await manifestIcons(url)
                } else if rel.contains("icon") {
                    let size = attribute("sizes", in: tag).flatMap { Int($0.split(separator: "x").first ?? "") }
                    candidates.append((url, size ?? (rel.contains("apple-touch") ? 180 : 32)))
                }
            }
        }
        for path in ["/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"] {
            if let url = URL(string: path, relativeTo: site)?.absoluteURL { candidates.append((url, 180)) }
        }
        for candidate in candidates.sorted(by: { $0.size > $1.size }) {
            if let data = await fetchImage(candidate.url, minimumSide: 96) { return data }
        }
        return nil
    }

    private static func manifestIcons(_ url: URL) async -> [(url: URL, size: Int)] {
        guard let data = await fetch(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icons = json["icons"] as? [[String: Any]] else { return [] }
        return icons.compactMap { icon in
            guard let src = icon["src"] as? String, let iconURL = URL(string: src, relativeTo: url)?.absoluteURL else { return nil }
            let size = (icon["sizes"] as? String)?.split(separator: " ").compactMap { Int($0.split(separator: "x").first ?? "") }.max()
            return (iconURL, size ?? 192)
        }
    }

    // MARK: Helpers

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(UserAgent.safari, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { return nil }
        return data
    }

    /// Downloads an image and returns it as PNG, if it's a real image of a usable size.
    private static func fetchImage(_ url: URL, minimumSide: Int = 0) async -> Data? {
        guard let data = await fetch(url), let image = NSImage(data: data),
              let rep = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }),
              rep.pixelsWide >= minimumSide,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }
}

/// Mac apps installed on this machine, for adding to the home screen.
enum InstalledApps {
    struct App: Hashable {
        let name: String
        let bundleID: String
        let path: String
    }

    static let all: [App] = {
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       NSHomeDirectory() + "/Applications"]
        var found: [String: App] = [:]
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where name.hasSuffix(".app") {
                let path = folder + "/" + name
                guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier,
                      id != Bundle.main.bundleIdentifier else { continue }
                let display = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? String(name.dropLast(4))
                found[id] = App(name: display, bundleID: id, path: path)
            }
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    static func matching(_ query: String) -> [App] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(all.prefix(40)) }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(40).map { $0 }
    }
}
