import AppKit
import ImageIO
import SwiftUI

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
    /// Countries (ISO codes) where a built-in service streams; nil for everywhere. Elsewhere it isn't
    /// built in, since it would only open on a "not available in your region" page; it can still be added.
    var regions: Set<String>? = nil
    /// App Store search term when `name` is ambiguous (e.g. My5 → "Channel 5", CTV → "CTV+").
    var iconQuery: String? = nil

    /// Installed, and streams in this Mac's region.
    var isAvailable: Bool {
        guard isInstalled else { return false }
        guard let regions else { return true }
        return Locale.current.region.map { regions.contains($0.identifier) } ?? false
    }

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
                accent: "#16C6B0", deep: "#06312D", regions: ["GB"]),
        Service(id: "channel4", name: "Channel 4", kind: .web(URL(string: "https://www.channel4.com/")!),
                accent: "#ED1664", deep: "#320B1A", regions: ["GB"]),
        Service(id: "movies", name: "Movies", kind: .movies, accent: "#5E5CE6", deep: "#14133A"),
        Service(id: "iina", name: "IINA", kind: .app(bundleID: "com.colliderli.iina"),
                icon: "iina.png"),
        Service(id: "add-app", name: "Add App", kind: .addApp, accent: "#636366", deep: "#1C1C1E"),
        Service(id: "settings", name: "Settings", kind: .settings, accent: "#8E8E93", deep: "#2C2C2E"),
    ]

    /// Extra streaming sites under Add App › Suggested (not on the home screen by default).
    /// `regions: nil` = worldwide (*Included*); otherwise local (*Suggested for you* when the
    /// Mac's region matches, else behind *More services*).
    static let websiteSuggestions: [Service] = [
        // Global
        Service(id: "disney", name: "Disney+", kind: .web(URL(string: "https://www.disneyplus.com")!),
                accent: "#113CCF", deep: "#06103A"),
        Service(id: "max", name: "HBO Max", kind: .web(URL(string: "https://www.hbomax.com")!),
                accent: "#002BE7", deep: "#01082E"),
        Service(id: "paramount", name: "Paramount+", kind: .web(URL(string: "https://www.paramountplus.com")!),
                accent: "#0064FF", deep: "#021433"),
        Service(id: "crunchyroll", name: "Crunchyroll", kind: .web(URL(string: "https://www.crunchyroll.com")!),
                accent: "#F47521", deep: "#3A1604"),
        Service(id: "twitch", name: "Twitch", kind: .web(URL(string: "https://www.twitch.tv")!),
                accent: "#9146FF", deep: "#1C0B33"),
        Service(id: "dazn", name: "DAZN", kind: .web(URL(string: "https://www.dazn.com")!),
                accent: "#F7FF1A", deep: "#2A2C05"),
        Service(id: "pluto", name: "Pluto TV", kind: .web(URL(string: "https://pluto.tv")!),
                accent: "#FFF200", deep: "#1A1600"),
        // DE / AT / CH
        Service(id: "joyn", name: "Joyn", kind: .web(URL(string: "https://www.joyn.de")!),
                accent: "#0ADEC6", deep: "#04332E", regions: ["DE", "AT", "CH"]),
        Service(id: "rtlplus", name: "RTL+", kind: .web(URL(string: "https://plus.rtl.de")!),
                accent: "#E4002B", deep: "#2E050C", regions: ["DE", "AT", "CH"]),
        Service(id: "arte", name: "Arte", kind: .web(URL(string: "https://www.arte.tv")!),
                accent: "#FF6A00", deep: "#3A1600", regions: ["DE", "FR", "AT", "CH", "BE"],
                iconQuery: "ARTE Mediathek"),
        Service(id: "ard", name: "ARD Mediathek", kind: .web(URL(string: "https://www.ardmediathek.de")!),
                accent: "#003D70", deep: "#011526", regions: ["DE", "AT", "CH"]),
        Service(id: "zdf", name: "ZDF", kind: .web(URL(string: "https://www.zdf.de")!),
                accent: "#FA7D19", deep: "#3A1A04", regions: ["DE", "AT", "CH"]),
        // FR (myCanal omitted — editorial)
        Service(id: "francetv", name: "France.tv", kind: .web(URL(string: "https://www.france.tv")!),
                accent: "#000091", deep: "#010133", regions: ["FR"], iconQuery: "france.tv"),
        Service(id: "tf1plus", name: "TF1+", kind: .web(URL(string: "https://www.tf1.fr")!),
                accent: "#1A1A1A", deep: "#0A0A0A", regions: ["FR"], iconQuery: "TF1+"),
        Service(id: "m6plus", name: "M6+", kind: .web(URL(string: "https://www.m6.fr/m6plus")!),
                accent: "#FF6B00", deep: "#3A1600", regions: ["FR"], iconQuery: "M6+"),
        // GB
        Service(id: "bbciplayer", name: "BBC iPlayer", kind: .web(URL(string: "https://www.bbc.co.uk/iplayer")!),
                accent: "#FFD500", deep: "#2A2200", regions: ["GB"]),
        Service(id: "my5", name: "My5", kind: .web(URL(string: "https://www.channel5.com")!),
                accent: "#00A0DC", deep: "#042433", regions: ["GB"], iconQuery: "Channel 5"),
        Service(id: "now", name: "NOW", kind: .web(URL(string: "https://www.nowtv.com")!),
                accent: "#6C2BD9", deep: "#1A0833", regions: ["GB"], iconQuery: "NOW"),
        // US
        Service(id: "hulu", name: "Hulu", kind: .web(URL(string: "https://www.hulu.com")!),
                accent: "#1CE783", deep: "#062816", regions: ["US"]),
        Service(id: "peacock", name: "Peacock", kind: .web(URL(string: "https://www.peacocktv.com")!),
                accent: "#F4A6C9", deep: "#2A1520", regions: ["US"]),
        Service(id: "espn", name: "ESPN", kind: .web(URL(string: "https://www.espn.com")!),
                accent: "#E4002B", deep: "#2E050C", regions: ["US"]),
        Service(id: "tubi", name: "Tubi", kind: .web(URL(string: "https://tubitv.com")!),
                accent: "#FA3825", deep: "#2E0805", regions: ["US"]),
        // CA
        Service(id: "crave", name: "Crave", kind: .web(URL(string: "https://www.crave.ca")!),
                accent: "#E50914", deep: "#2B0204", regions: ["CA"]),
        Service(id: "cbcgem", name: "CBC Gem", kind: .web(URL(string: "https://gem.cbc.ca")!),
                accent: "#E60505", deep: "#2B0202", regions: ["CA"]),
        Service(id: "ctv", name: "CTV", kind: .web(URL(string: "https://www.ctv.ca")!),
                accent: "#0096D6", deep: "#022433", regions: ["CA"], iconQuery: "CTV+"),
        // IN
        Service(id: "sonyliv", name: "SonyLIV", kind: .web(URL(string: "https://www.sonyliv.com")!),
                accent: "#000000", deep: "#111111", regions: ["IN"], iconQuery: "Sony LIV"),
        Service(id: "zee5", name: "ZEE5", kind: .web(URL(string: "https://www.zee5.com")!),
                accent: "#8230C9", deep: "#1A0833", regions: ["IN"], iconQuery: "Zee 5"),
        // AU
        Service(id: "stan", name: "Stan", kind: .web(URL(string: "https://www.stan.com.au")!),
                accent: "#00A9E0", deep: "#022433", regions: ["AU"]),
        Service(id: "binge", name: "Binge", kind: .web(URL(string: "https://binge.com.au")!),
                accent: "#FF288C", deep: "#330A1C", regions: ["AU"]),
        Service(id: "abciview", name: "ABC iview", kind: .web(URL(string: "https://iview.abc.net.au")!),
                accent: "#000000", deep: "#111111", regions: ["AU"]),
        Service(id: "sbsondemand", name: "SBS On Demand", kind: .web(URL(string: "https://www.sbs.com.au/ondemand")!),
                accent: "#FF6200", deep: "#3A1600", regions: ["AU"], iconQuery: "SBS On Demand"),
        // JP
        Service(id: "unext", name: "U-NEXT", kind: .web(URL(string: "https://video.unext.jp")!),
                accent: "#00C300", deep: "#022A02", regions: ["JP"]),
        Service(id: "abema", name: "ABEMA", kind: .web(URL(string: "https://abema.tv")!),
                accent: "#00C3A0", deep: "#022A22", regions: ["JP"], iconQuery: "ABEMA"),
        Service(id: "tver", name: "TVer", kind: .web(URL(string: "https://tver.jp")!),
                accent: "#1A1A1A", deep: "#0A0A0A", regions: ["JP"]),
        // BR
        Service(id: "globoplay", name: "Globoplay", kind: .web(URL(string: "https://globoplay.globo.com")!),
                accent: "#F56700", deep: "#3A1600", regions: ["BR"]),
        // IT
        Service(id: "raiplay", name: "RaiPlay", kind: .web(URL(string: "https://www.raiplay.it")!),
                accent: "#00A0E3", deep: "#022433", regions: ["IT"]),
        Service(id: "mediasetinfinity", name: "Mediaset Infinity",
                kind: .web(URL(string: "https://www.mediasetinfinity.mediaset.it")!),
                accent: "#0066CC", deep: "#021433", regions: ["IT"], iconQuery: "Mediaset Infinity Italia"),
        Service(id: "nowit", name: "NOW", kind: .web(URL(string: "https://www.nowtv.it")!),
                accent: "#6C2BD9", deep: "#1A0833", regions: ["IT"], iconQuery: "NOW"),
        // NL
        Service(id: "videoland", name: "Videoland", kind: .web(URL(string: "https://www.videoland.com")!),
                accent: "#E31C23", deep: "#2E0508", regions: ["NL"]),
        Service(id: "npostart", name: "NPO Start", kind: .web(URL(string: "https://www.npostart.nl")!),
                accent: "#FF6D00", deep: "#3A1600", regions: ["NL"]),
        Service(id: "nlziet", name: "NLZIET", kind: .web(URL(string: "https://www.nlziet.nl")!),
                accent: "#00A0E2", deep: "#022433", regions: ["NL"]),
    ]

    /// Tests may pin a region; otherwise the Mac's Locale region.
    nonisolated(unsafe) static var suggestionRegionOverride: String?

    /// ISO region for Suggested sections.
    static var suggestionRegion: String? {
        suggestionRegionOverride ?? Locale.current.region?.identifier
    }

    /// Whether this service's `regions` include the Mac (or override) region. Nil regions = worldwide.
    static func matchesSuggestionRegion(_ service: Service, region: String? = nil) -> Bool {
        let region = region ?? suggestionRegion
        guard let regions = service.regions else { return true }
        guard let region else { return true }
        return regions.contains(region)
    }
}

/// Brand icons for Add App › Suggested, from the App Store only, cached on disk. Browsing the list
/// doesn't contact the streaming sites; adding one finds its icon the usual way.
@MainActor
enum SuggestionIcons {
    private static var memory: [String: NSImage] = [:]
    /// Services the App Store had no icon for, so reopening the list doesn't ask again this session.
    private static var missing: Set<String> = []

    private static func file(for id: String) -> URL {
        AppFolder.url.appendingPathComponent("Icons", isDirectory: true)
            .appendingPathComponent("suggest-\(id).png")
    }

    static func image(for service: Service) -> NSImage? {
        // Bundled restore icons only — don't ask Icons for bare website presets (it would cache a nil).
        if service.icon != nil || service.iconFile != nil, let bundled = Icons.image(for: service) {
            return bundled
        }
        if let cached = memory[service.id] { return cached }
        let path = file(for: service.id)
        guard let image = NSImage(contentsOf: path), image.size.width > 0 else { return nil }
        memory[service.id] = image
        return image
    }

    /// Pulls missing logos in list order so the first rows fill first.
    static func prefetch(_ services: [Service], onEach: @MainActor () -> Void = {}) async {
        for service in services {
            guard case .web = service.kind else { continue }
            if image(for: service) != nil || missing.contains(service.id) { continue }
            guard let data = await IconFinder.storeIcon(named: service.iconQuery ?? service.name, regions: service.regions),
                  let image = NSImage(data: data) else { missing.insert(service.id); continue }
            Log.app.attempt("Saving a suggested app icon") {
                try data.write(to: file(for: service.id), options: .atomic)
            }
            memory[service.id] = image
            onEach()
        }
    }
}

/// Icon artwork for tiles and for the phone remote's app list.
@MainActor
enum Icons {
    private static var images: [String: NSImage] = [:]
    private static var pngs: [String: Data] = [:]

    static func image(for service: Service) -> NSImage? {
        if let cached = images[service.id] { return cached }
        // Don't cache misses — the file often appears a moment after the first ask.
        guard let image = sourceImage(for: service, maxPixels: 512) else { return nil }
        images[service.id] = image
        return image
    }

    /// Icons are often 1024 px; dock tiles draw them about 250 points wide, so 512 px is plenty sharp.
    private static func decoded(_ url: URL, maxPixels: Int = 512) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return NSImage(contentsOf: url) }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func sourceImage(for service: Service, maxPixels: Int) -> NSImage? {
        if let file = service.iconFile { return decoded(file, maxPixels: maxPixels) }
        if let file = service.icon,
           let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "Icons") {
            return decoded(url, maxPixels: maxPixels)
        }
        return nil
    }

    /// `cgImage(forProposedRect: nil)` often returns nil for workspace-drawn Mac icons; TIFF is the fallback.
    static func cgImage(for service: Service, maxPixels: Int = 1024) -> CGImage? {
        if let system = systemSymbolImage(for: service) { return system }
        guard let image = sourceImage(for: service, maxPixels: maxPixels) else { return nil }
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.cgImage
    }

    /// Built-in Add App / Settings marks for TileArt (same path as Mac app icons).
    private static func systemSymbolImage(for service: Service) -> CGImage? {
        switch service.kind {
        case .addApp:
            return drawSymbol("plus", groundHex: service.deep, weight: .medium, pointSize: 420)
        case .settings:
            return drawSymbol("gearshape.fill", groundHex: service.accent, weight: .regular, pointSize: 400)
        default:
            return nil
        }
    }

    private static func drawSymbol(_ name: String, groundHex: String, weight: NSFont.Weight, pointSize: CGFloat) -> CGImage? {
        let side = 1024
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(Color(hex: groundHex)).setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            NSColor.white.set()
            rect.fill()
            symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        let size = tinted.size
        let rect = NSRect(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2,
                          width: size.width, height: size.height)
        tinted.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    private static var tiles: [String: NSImage] = [:]
    private static var shelfArts: [String: NSImage] = [:]

    /// Drops cached artwork, after an app's icon arrives or the app is removed.
    static func forget(_ id: String) {
        images[id] = nil
        tiles[id] = nil
        shelfArts[id] = nil
        pngs[id] = nil
    }

    static func tile(for service: Service) -> NSImage? {
        if let cached = tiles[service.id] { return cached }
        let tile = service.hasWideArt ? image(for: service)
            : cgImage(for: service, maxPixels: 512).flatMap { TileArt.make(from: $0) }
        // Don't cache misses — artwork often arrives a moment after the tile is first asked for.
        if let tile { tiles[service.id] = tile }
        return tile
    }

    /// Full-bleed Top Shelf art: same TileArt layout as the dock, at ~1080p 5:3 from a 1024 px icon.
    /// The mark is centred in the band above the home dock, so the dock does not crop it.
    static func shelfArt(for service: Service) -> NSImage? {
        if let cached = shelfArts[service.id] { return cached }
        guard let cg = cgImage(for: service, maxPixels: 1024),
              let art = TileArt.make(from: cg, size: TileArt.shelfSize, markCenterY: TileArt.shelfMarkCenterY)
        else { return nil }
        shelfArts[service.id] = art
        return art
    }

    /// Draws Top Shelf art off the main thread ahead of time (about a tenth of a second each), so the
    /// first focus on each app doesn't stutter. Apps drawn on focus meanwhile are left as they are.
    static func prewarmShelfArt(for services: [Service]) async {
        struct Drawn: @unchecked Sendable { let image: NSImage? }
        for service in services {
            switch service.kind {
            case .app, .addApp, .settings: break
            default: continue
            }
            guard shelfArts[service.id] == nil, let cg = cgImage(for: service, maxPixels: 1024) else { continue }
            let drawn = await Task.detached(priority: .utility) {
                Drawn(image: TileArt.make(from: cg, size: TileArt.shelfSize, markCenterY: TileArt.shelfMarkCenterY))
            }.value
            if shelfArts[service.id] == nil, let image = drawn.image { shelfArts[service.id] = image }
        }
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
