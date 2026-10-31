import AppKit

struct Service: Identifiable, Hashable {
    enum Kind: Hashable {
        case web(URL)
        case app(bundleID: String)
        /// A Steam game, or Steam Big Picture, launched through Steam.
        case steam(appID: String)
        /// The movies in folders on this Mac.
        case movies
        case addApp
        case settings
    }

    let id: String
    let name: String
    let kind: Kind
    /// The service's square app icon, a file in Icons/ for built-in apps…
    var icon: String? = nil
    /// …or a file the user's app library saved, for apps they added.
    var iconFile: URL? = nil
    var accent = "#8E8E93"
    var deep = "#16171B"
    var userAgent: String = UserAgent.safari
    /// Inject D-pad focus navigation for sites that were built for a mouse.
    var dpadNavigation = true

    var isInstalled: Bool {
        switch kind {
        case .app(let bundleID): return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        case .steam: return SteamLibrary.isInstalled
        default: return true
        }
    }

    /// Steam games bring a ready-made wide tile (background and logo) instead of a square icon.
    var hasWideArt: Bool {
        if case .steam(let appID) = kind { return appID != SteamLibrary.bigPicture.appID }
        return false
    }

    var isWeb: Bool {
        if case .web = kind { return true }
        return false
    }
}

enum UserAgent {
    /// Streaming sites gate DRM and quality on the browser; present as Safari.
    static let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15"
    /// youtube.com/tv only serves its 10-foot interface to TV browsers.
    static let smartTV = "Mozilla/5.0 (Linux; Tizen 2.3) AppleWebKit/538.1 (KHTML, like Gecko)Version/2.3 TV Safari/538.1"
    /// Google's sign-in turns away browsers embedded in apps ("browser unsupported"); on its
    /// pages only, present as desktop Firefox, which it accepts.
    static let googleSignIn = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:144.0) Gecko/20100101 Firefox/144.0"
}

enum Catalog {
    /// The home screen, in order: the first six sit in the dock under the Top Shelf.
    /// Mac app tiles only appear when the app is installed.
    static let services: [Service] = [
        Service(id: "netflix", name: "Netflix", kind: .web(URL(string: "https://www.netflix.com/browse")!),
                icon: "netflix.png", accent: "#E50914", deep: "#2B0204"),
        Service(id: "youtube", name: "YouTube", kind: .web(URL(string: "https://www.youtube.com/tv")!),
                icon: "youtube.png", accent: "#FF2D2D", deep: "#2B0606",
                userAgent: UserAgent.smartTV, dpadNavigation: false),
        Service(id: "prime", name: "Prime Video", kind: .web(URL(string: "https://www.primevideo.com")!),
                icon: "prime.png", accent: "#1A98FF", deep: "#05213F"),
        Service(id: "hotstar", name: "JioHotstar", kind: .web(URL(string: "https://www.hotstar.com")!),
                icon: "hotstar.png", accent: "#2C6BED", deep: "#081538"),
        Service(id: "appletv", name: "Apple TV", kind: .web(URL(string: "https://tv.apple.com")!),
                icon: "appletv.png", accent: "#9A9AA2", deep: "#18181B"),
        Service(id: "spotify", name: "Spotify", kind: .web(URL(string: "https://open.spotify.com")!),
                icon: "spotify.png", accent: "#1ED760", deep: "#06210F"),
        Service(id: "ytmusic", name: "YouTube Music", kind: .web(URL(string: "https://music.youtube.com")!),
                icon: "ytmusic.png", accent: "#FF2D2D", deep: "#2B0606"),
        Service(id: "itvx", name: "ITVX", kind: .web(URL(string: "https://www.itv.com/watch")!),
                accent: "#16C6B0", deep: "#06312D"),
        Service(id: "channel4", name: "Channel 4", kind: .web(URL(string: "https://www.channel4.com/")!),
                accent: "#ED1664", deep: "#320B1A"),
        Service(id: "movies", name: "Movies", kind: .movies, accent: "#5E5CE6", deep: "#14133A"),
        Service(id: "iina", name: "IINA", kind: .app(bundleID: "com.colliderli.iina"),
                icon: "iina.png"),
        Service(id: "add-app", name: "Add App", kind: .addApp),
        Service(id: "settings", name: "Settings", kind: .settings),
    ]
}

/// Icon artwork for tiles and for the phone remote's app list.
@MainActor
enum Icons {
    private static var images: [String: NSImage] = [:]
    private static var pngs: [String: Data] = [:]

    static func image(for service: Service) -> NSImage? {
        if let cached = images[service.id] { return cached }
        var image: NSImage?
        if let file = service.iconFile {
            image = NSImage(contentsOf: file)
        } else if let file = service.icon,
           let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "Icons") {
            image = NSImage(contentsOf: url)
        }
        images[service.id] = image
        return image
    }

    private static var tiles: [String: NSImage] = [:]

    /// Drops cached artwork, after an app's icon arrives or the app is removed.
    static func forget(_ id: String) {
        images[id] = nil
        tiles[id] = nil
        pngs[id] = nil
    }

    static func tile(for service: Service) -> NSImage? {
        if let cached = tiles[service.id] { return cached }
        let tile = service.hasWideArt ? image(for: service)
            : image(for: service)?.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap { TileArt.make(from: $0) }
        tiles[service.id] = tile
        return tile
    }

    static func png(for service: Service) -> Data? {
        if let cached = pngs[service.id] { return cached }
        guard let image = image(for: service), let tiff = image.tiffRepresentation,
              let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        pngs[service.id] = data
        return data
    }
}
