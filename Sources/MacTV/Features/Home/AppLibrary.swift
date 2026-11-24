import AppKit

/// ~/Library/Application Support/Mac TV, where added apps and their icons live.
/// Data from the app's earlier name ("Matinee") moves over on first run.
enum AppFolder {
    static let url: URL = {
        if let path = ProcessInfo.processInfo.environment["MACTV_DATA_DIR"], path.hasPrefix("/") {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Mac TV", isDirectory: true)
        let earlier = support.appendingPathComponent("Matinee", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path), FileManager.default.fileExists(atPath: earlier.path) {
            Log.app.attempt("Moving the Matinee folder") { try FileManager.default.moveItem(at: earlier, to: folder) }
        }
        Log.app.attempt("Creating the data folder") {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // Earlier versions kept a list of what was watched; Mac TV no longer records one.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("history.json"))
        return folder
    }()
}

/// An app the user added: a website, or a Mac app.
struct AddedApp: Codable, Hashable {
    let id: String
    var name: String
    var url: URL?
    var bundleID: String?
    var steamID: String?
    /// The icon's brand colour, found once the icon arrives; tints its Top Shelf.
    var accent: String?
}

/// The home screen's apps: the built-in catalog minus any the user removed, plus the apps they
/// added, then Settings. Kept in ~/Library/Application Support/Mac TV/apps.json, or
/// apps-<profile>.json for profiles after the first.
@MainActor
final class AppLibrary {
    private struct Saved: Codable {
        var added: [AddedApp] = []
        var hidden: Set<String> = []
        var order: [String] = []
        var pinned: Set<String> = []

        init() {}

        private enum CodingKeys: String, CodingKey { case added, hidden, order, pinned }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            added = try values.decodeIfPresent([AddedApp].self, forKey: .added) ?? []
            hidden = try values.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
            order = try values.decodeIfPresent([String].self, forKey: .order) ?? []
            pinned = try values.decodeIfPresent(Set<String>.self, forKey: .pinned) ?? []
        }
    }

    private var saved = Saved()
    private let file: URL
    /// Added apps' ids start with this, so two profiles adding the same site keep separate icons.
    private let idPrefix: String
    let iconsFolder: URL

    let storageFolder: URL

    init(profileID: String = Profile.mainID, folder: URL = AppFolder.url) {
        storageFolder = folder
        let icons = folder.appendingPathComponent("Icons", isDirectory: true)
        iconsFolder = icons
        Log.app.attempt("Creating the icons folder") {
            try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        }
        let main = profileID == Profile.mainID
        file = folder.appendingPathComponent(main ? "apps.json" : "apps-\(profileID).json")
        idPrefix = main ? "user-" : "user-\(profileID)-"
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = decoded
        }
    }

    var hasHiddenBuiltIns: Bool { !saved.hidden.isEmpty }
    /// The removed built-in apps that restoring would bring back to this Mac's home screen.
    var hiddenBuiltInCount: Int { Catalog.services.filter { saved.hidden.contains($0.id) && $0.isAvailable }.count }
    /// The user has added or removed an app at some point.
    var hasSavedApps: Bool { FileManager.default.fileExists(atPath: file.path) }

    func isHidden(_ id: String) -> Bool { saved.hidden.contains(id) }

    /// Shows or hides a built-in app, for first-run setup. False when the change couldn't be saved.
    @discardableResult
    func setHidden(_ id: String, _ hidden: Bool) -> Bool {
        let previous = saved.hidden
        if hidden { saved.hidden.insert(id) } else { saved.hidden.remove(id) }
        guard save() else { saved.hidden = previous; return false }
        return true
    }

    func services() -> [Service] {
        let visible = orderedApps.filter { !saved.hidden.contains($0.id) && $0.isAvailable }
        let tail = Catalog.services.filter { !Self.canArrange($0) }
        return visible.filter { isPinned($0.id) } + visible.filter { !isPinned($0.id) } + tail
    }

    private static func canArrange(_ service: Service) -> Bool {
        service.kind != .addApp && service.kind != .settings
    }

    /// Includes hidden and temporarily unavailable apps, so their positions survive restoration.
    private var orderedApps: [Service] {
        let apps = Catalog.services.filter(Self.canArrange) + saved.added.compactMap(service(for:))
        var remaining = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = saved.order.compactMap { remaining.removeValue(forKey: $0) }
        return ordered + apps.filter { remaining.removeValue(forKey: $0.id) != nil }
    }

    func isPinned(_ id: String) -> Bool { saved.pinned.contains(id) }

    @discardableResult
    func setPinned(_ id: String, _ pinned: Bool) -> Bool {
        guard services().contains(where: { $0.id == id && Self.canArrange($0) }) else { return false }
        let previous = saved.pinned
        if pinned { saved.pinned.insert(id) } else { saved.pinned.remove(id) }
        guard save() else { saved.pinned = previous; return false }
        return true
    }

    private func neighbour(of id: String, by offset: Int) -> String? {
        guard offset == -1 || offset == 1 else { return nil }
        let group = services().filter { Self.canArrange($0) && isPinned($0.id) == isPinned(id) }
        guard let index = group.firstIndex(where: { $0.id == id }), group.indices.contains(index + offset) else { return nil }
        return group[index + offset].id
    }

    func canMove(_ id: String, by offset: Int) -> Bool { neighbour(of: id, by: offset) != nil }

    @discardableResult
    func move(_ id: String, by offset: Int) -> Bool {
        guard let neighbour = neighbour(of: id, by: offset) else { return false }
        var order = orderedApps.map(\.id)
        guard let from = order.firstIndex(of: id), let to = order.firstIndex(of: neighbour) else { return false }
        order.swapAt(from, to)
        let previous = saved.order
        saved.order = order
        guard save() else { saved.order = previous; return false }
        return true
    }

    func iconFile(for id: String) -> URL { iconsFolder.appendingPathComponent("\(id).png") }
    /// Steam library hero (often 3840×1240) for the Top Shelf; separate from the dock tile PNG.
    func heroFile(for id: String) -> URL { iconsFolder.appendingPathComponent("\(id)-hero.jpg") }

    private func service(for app: AddedApp) -> Service? {
        let kind: Service.Kind
        if let url = app.url { kind = .web(url) }
        else if let bundleID = app.bundleID { kind = .app(bundleID: bundleID) }
        else if let steamID = app.steamID { kind = .steam(appID: steamID) }
        else { return nil }
        let icon = iconFile(for: app.id)
        let accent = app.accent ?? "#8E8E93"
        return Service(id: app.id, name: app.name, kind: kind,
                       iconFile: FileManager.default.fileExists(atPath: icon.path) ? icon : nil,
                       accent: accent, deep: TileArt.brandDeep(fromAccent: accent))
    }

    @discardableResult
    func add(name: String, url: URL?, bundleID: String?, steamID: String? = nil) -> AddedApp {
        let base = name.lowercased().filter { $0.isLetter || $0.isNumber }
        var id = idPrefix + (base.isEmpty ? "app" : base)
        let taken = Set(Catalog.services.map(\.id) + saved.added.map(\.id))
        if taken.contains(id) { id += "-\(Int.random(in: 1000...9999))" }
        let app = AddedApp(id: id, name: name, url: url, bundleID: bundleID, steamID: steamID)
        // A new app must not inherit an obsolete entry from an older library file.
        saved.order.removeAll { $0 == id }
        saved.pinned.remove(id)
        saved.added.append(app)
        save()
        return app
    }

    func containsAddedApp(_ id: String) -> Bool { saved.added.contains { $0.id == id } }

    func setIcon(_ png: Data, accent: String?, for id: String) {
        guard containsAddedApp(id) else { return }
        Log.app.attempt("Saving an app icon") { try png.write(to: iconFile(for: id), options: .atomic) }
        // Keep a catalog/preset accent when the icon has no extractable brand colour.
        if let accent, let index = saved.added.firstIndex(where: { $0.id == id }) {
            saved.added[index].accent = accent
            save()
        }
    }

    func setHero(_ jpeg: Data, for id: String) {
        guard containsAddedApp(id) else { return }
        Log.app.attempt("Saving Steam hero art") { try jpeg.write(to: heroFile(for: id), options: .atomic) }
        SteamShelfArt.forget(heroFile(for: id))
    }

    /// Removes an added app, or hides a built-in one. False when there's no such app to remove, or
    /// the change couldn't be saved; the library is then left as it was.
    @discardableResult
    func remove(_ id: String) -> Bool {
        let previous = saved
        if let index = saved.added.firstIndex(where: { $0.id == id }) {
            saved.added.remove(at: index)
            saved.order.removeAll { $0 == id }
            saved.pinned.remove(id)
            guard save() else { saved = previous; return false }
            try? FileManager.default.removeItem(at: iconFile(for: id))
            try? FileManager.default.removeItem(at: heroFile(for: id))
            SteamShelfArt.forget(heroFile(for: id))
            return true
        }
        guard Catalog.services.contains(where: { $0.id == id && Self.canArrange($0) }) else { return false }
        saved.hidden.insert(id)
        guard save() else { saved = previous; return false }
        return true
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try JSONEncoder().encode(saved).write(to: file, options: .atomic)
            return true
        } catch { return false }
    }

}

/// Finds an official-looking square icon for an app the user adds.
enum IconFinder {
    /// For a website: its App Store app's icon (crisp, 1024 px) when the name matches one,
    /// else the largest home-screen icon the site publishes.
    /// `regions` prefers those App Store storefronts (e.g. FR for TF1+) before the Mac's.
    static func icon(forSite site: URL, name: String, regions: Set<String>? = nil) async -> Data? {
        if let data = await appStoreIcon(named: name, regions: regions) { return data }
        return await siteIcon(site)
    }

    /// A Mac app's own icon.
    @MainActor
    static func icon(forAppAt path: String) -> Data? {
        // Workspace icons load lazily — drawing them immediately often saves a blank tile.
        // Round-trip through TIFF so the real pixels are in memory before we rasterise.
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 512, height: 512)
        guard let tiff = image.tiffRepresentation, let ready = NSImage(data: tiff) else { return nil }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        ready.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// The App Store icon alone, for previews that shouldn't contact the site itself.
    static func storeIcon(named name: String, regions: Set<String>? = nil) async -> Data? {
        await appStoreIcon(named: name, regions: regions)
    }

    /// Searches the storefronts where the service streams, then the Mac's, then the US.
    private static func appStoreIcon(named name: String, regions: Set<String>? = nil) async -> Data? {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return nil }
        var countries: [String] = []
        var seen = Set<String>()
        for code in (regions ?? []).sorted() + [Locale.current.region?.identifier ?? "US", "US"] {
            let upper = code.uppercased()
            if seen.insert(upper).inserted { countries.append(upper) }
        }
        for country in countries {
            if let data = await appStoreIcon(named: name, wanted: wanted, country: country) { return data }
        }
        return nil
    }

    private static func appStoreIcon(named name: String, wanted: String, country: String) async -> Data? {
        var query = URLComponents(string: "https://itunes.apple.com/search")!
        query.queryItems = [.init(name: "term", value: name), .init(name: "entity", value: "software"),
                            .init(name: "limit", value: "8"),
                            .init(name: "country", value: country)]
        guard let url = query.url, let data = await fetch(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        // Prefer exact / TV-ish suffixes so "Arte"→Mediathek/TV, not ARTE Radio; "TF1+"≠"TF1 INFO".
        let match = results.compactMap { result -> (score: Int, artwork: String)? in
            let title = normalized(result["trackName"] as? String ?? "")
            guard let artwork = result["artworkUrl512"] as? String else { return nil }
            let score: Int?
            if title == wanted { score = 0 }
            else if title.hasPrefix(wanted), title.count <= wanted.count + 24 {
                let rest = title.dropFirst(wanted.count)
                if rest.isEmpty
                    || rest.hasPrefix("tv") || rest.hasPrefix("plus") || rest.hasPrefix("mediathek")
                    || rest.hasPrefix("play") || rest.hasPrefix("go") || rest.hasPrefix("liv") {
                    score = rest.count
                } else {
                    score = 100 + rest.count
                }
            } else if wanted.count > 3, wanted.hasPrefix(title), title.count > 3 {
                score = wanted.count - title.count + 50
            } else { score = nil }
            return score.map { ($0, artwork) }
        }.min(by: { $0.score < $1.score })
        guard let artwork = match?.artwork,
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
