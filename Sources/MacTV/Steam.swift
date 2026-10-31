import AppKit

/// Steam games installed on this Mac, read from Steam's own library files, and their artwork.
///
/// Games are launched through Steam (`steam://rungameid/…`), so DRM, cloud saves and updates work
/// as they do from Steam itself.
enum SteamLibrary {
    struct Game: Hashable {
        let appID: String
        let name: String
    }

    static let bundleID = "com.valvesoftware.steam"
    /// Steam's own TV mode, offered first in the list.
    static let bigPicture = Game(appID: "bigpicture", name: "Steam Big Picture")
    /// Installs that aren't games.
    private static let tools: Set<String> = ["228980"]  // Steamworks Common Redistributables

    static var isInstalled: Bool { appURL != nil }
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    /// Steam's folder. `MACTV_STEAM_ROOT` points it elsewhere, for checking against sample files.
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["MACTV_STEAM_ROOT"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
    }

    static func launchURL(for appID: String) -> URL {
        URL(string: appID == bigPicture.appID ? "steam://open/bigpicture" : "steam://rungameid/\(appID)")!
    }

    /// Fully installed games in every Steam library folder, by name.
    static func installedGames(root: URL = root) -> [Game] {
        let vdf = (try? String(contentsOf: root.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8)) ?? ""
        var folders = libraryFolders(in: vdf).map { URL(fileURLWithPath: $0) }
        if !folders.contains(root) { folders.insert(root, at: 0) }
        var games: [String: Game] = [:]
        for folder in folders {
            let steamapps = folder.appendingPathComponent("steamapps")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: steamapps.path)) ?? []
            for name in names where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: steamapps.appendingPathComponent(name), encoding: .utf8),
                      let game = game(inManifest: text) else { continue }
                games[game.appID] = game
            }
        }
        return games.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The "path" entries of libraryfolders.vdf: every drive Steam keeps games on.
    static func libraryFolders(in vdf: String) -> [String] {
        values(for: "path", in: vdf).map { $0.replacingOccurrences(of: "\\\\", with: "\\") }
    }

    /// A game from an appmanifest_<id>.acf, if it's fully installed and not a tool.
    static func game(inManifest text: String) -> Game? {
        guard let appID = values(for: "appid", in: text).first, let name = values(for: "name", in: text).first,
              !tools.contains(appID) else { return nil }
        // StateFlags 4 means fully installed; anything still downloading leaves it out.
        let flags = Int(values(for: "StateFlags", in: text).first ?? "") ?? 0
        guard flags & 4 != 0 else { return nil }
        return Game(appID: appID, name: name)
    }

    /// Values of `"key" "value"` pairs in Valve's KeyValues text format.
    private static func values(for key: String, in text: String) -> [String] {
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s+\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // MARK: Artwork

    /// A 5:3 tile like Steam's own TV mode: the game's wide background with its logo centred on it.
    /// Falls back to the store header image. Downloads from Steam's servers.
    static func tile(for appID: String) async -> Data? {
        let base = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/"
        async let hero = image(at: base + "library_hero.jpg")
        async let logo = image(at: base + "logo.png")
        async let header = image(at: base + "header.jpg")
        let (background, mark, fallback) = await (hero, logo, header)
        guard let picture = background ?? fallback else { return nil }
        return compose(background: picture, logo: background == nil ? nil : mark)
    }

    private static func image(at address: String) async -> CGImage? {
        guard let url = URL(string: address),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func compose(background: CGImage, logo: CGImage?) -> Data? {
        let size = CGSize(width: 1000, height: 600)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        // The background fills the tile.
        let scale = max(size.width / CGFloat(background.width), size.height / CGFloat(background.height))
        let drawn = CGSize(width: CGFloat(background.width) * scale, height: CGFloat(background.height) * scale)
        ctx.draw(background, in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
        if let logo {
            // A soft shade keeps the logo readable over bright art.
            let shade = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0, alpha: 0.35), CGColor(gray: 0, alpha: 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(shade, startCenter: CGPoint(x: size.width / 2, y: size.height / 2), startRadius: 0,
                                   endCenter: CGPoint(x: size.width / 2, y: size.height / 2), endRadius: size.width * 0.55, options: [])
            let fit = min(size.width * 0.74 / CGFloat(logo.width), size.height * 0.5 / CGFloat(logo.height))
            let w = CGFloat(logo.width) * fit, h = CGFloat(logo.height) * fit
            ctx.draw(logo, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        }
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

extension TVController {
    /// When a Steam game starts, Mac TV notes it, and comes back to the front when it quits.
    func watchForSteamGame() {
        steamWatchUntil = Date().addingTimeInterval(120)
        guard steamObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        steamObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app, let until = self.steamWatchUntil, Date() < until,
                      app.bundleIdentifier != SteamLibrary.bundleID, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                self.steamGamePID = app.processIdentifier
                self.steamWatchUntil = nil
            }
        })
        steamObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app, app.processIdentifier == self.steamGamePID else { return }
                self.steamGamePID = nil
                self.bringToFront()
                self.showToast("Welcome back")
            }
        })
    }
}
