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

    /// Full-bleed Top Shelf art: a full-colour store screenshot (unlike Steam's blue-tinted page backgrounds),
    /// then the library hero. Kept separate from the dock tile's logo composite.
    static func hero(for appID: String) async -> Data? {
        guard appID != bigPicture.appID else { return nil }
        if let shot = await storeScreenshot(for: appID) { return shot }
        let base = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/"
        for name in ["library_hero_2x.jpg", "library_hero.jpg", "header.jpg"] {
            if let data = await data(at: base + name) { return data }
        }
        return nil
    }

    /// First store screenshot for the app (1920×1080 when Steam has one).
    private static func storeScreenshot(for appID: String) async -> Data? {
        let api = "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=screenshots"
        guard let meta = await data(at: api),
              let json = try? JSONSerialization.jsonObject(with: meta) as? [String: Any],
              let entry = json[appID] as? [String: Any],
              let payload = entry["data"] as? [String: Any],
              let shots = payload["screenshots"] as? [[String: Any]],
              let path = shots.first?["path_full"] as? String else { return nil }
        return await data(at: path)
    }

    /// A few well-known titles for Top Shelf art checks (need not be installed).
    static let shelfArtSamples: [Game] = [
        Game(appID: "292030", name: "The Witcher 3: Wild Hunt"),
        Game(appID: "1091500", name: "Cyberpunk 2077"),
        Game(appID: "1245620", name: "ELDEN RING"),
        Game(appID: "1174180", name: "Red Dead Redemption 2"),
        Game(appID: "814380", name: "Sekiro: Shadows Die Twice"),
    ]

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

    private static func data(at address: String) async -> Data? {
        guard let url = URL(string: address),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    private static func image(at address: String) async -> CGImage? {
        guard let data = await data(at: address),
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
    /// When a Steam game starts, Mac TV notes it, fills the TV, then hands off the launch cover.
    func watchForSteamGame() {
        steamWatchUntil = Date().addingTimeInterval(120)
        ensureSteamObservers()
        suppressSteamUIWhileLaunchingGame()
    }

    /// Big Picture is Steam itself — wait for Steam, then fullscreen + cover hand-off.
    func watchForSteamBigPicture() {
        steamWatchUntil = Date().addingTimeInterval(120)
        ensureSteamObservers()
        if let steam = NSRunningApplication.runningApplications(withBundleIdentifier: SteamLibrary.bundleID)
            .first(where: { !$0.isTerminated }) {
            steamGamePID = steam.processIdentifier
            steamWatchUntil = nil
            handOffExternalLaunch(pid: steam.processIdentifier)
        }
    }

    /// Steam client / helpers (WebHelper, IPC, …) — never treat these as the game.
    private func isSteamFamily(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        return id == SteamLibrary.bundleID || id.hasPrefix("com.valvesoftware.")
    }

    private func ensureSteamObservers() {
        guard steamObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let onAppNote: (Notification) -> Void = { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.noteSteamLaunchCandidate(app) }
        }
        steamObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: onAppNote))
        // steam:// brings Steam forward over our cover — pull Mac TV back until the game is ready.
        steamObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                self.noteSteamLaunchCandidate(app)
                if let app, self.isSteamFamily(app) {
                    self.suppressSteamUIWhileLaunchingGame()
                }
                self.keepLaunchCoverInFrontIfNeeded(activated: app)
                self.keepGameInFrontIfSteamSteals(activated: app)
            }
        })
        steamObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app, app.processIdentifier == self.steamGamePID else { return }
                self.steamGamePID = nil
                self.openedSteam = false
                self.bringToFront()
                self.showToast("Welcome back")
            }
        })
    }

    /// First real game process (regular app, not Steam / Mac TV) while the cover is waiting.
    private func noteSteamLaunchCandidate(_ app: NSRunningApplication?) {
        guard let app, let until = steamWatchUntil, Date() < until,
              launchCover != nil, launchCover?.canceling != true,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        let waitingForBigPicture: Bool = {
            if case .steam(let appID) = launchCover?.service.kind {
                return appID == SteamLibrary.bigPicture.appID
            }
            return false
        }()

        if waitingForBigPicture {
            guard app.bundleIdentifier == SteamLibrary.bundleID else { return }
        } else {
            // Ignore Steam, Valve helpers, and background agents — wait for the game itself.
            if isSteamFamily(app) {
                suppressSteamUIWhileLaunchingGame()
                return
            }
            guard app.activationPolicy == .regular else { return }
        }

        steamGamePID = app.processIdentifier
        steamWatchUntil = nil
        suppressSteamUIWhileLaunchingGame()
        handOffExternalLaunch(pid: app.processIdentifier)
    }

    /// Hide Steam (and drop its fullscreen) so only Mac TV's cover, then the game, is visible.
    func suppressSteamUIWhileLaunchingGame() {
        if case .steam(let appID) = launchCover?.service.kind, appID == SteamLibrary.bigPicture.appID { return }
        if launchCover?.canceling == true { return }
        // During cover, or after hand-off while we still own the Steam game session.
        let duringCover = launchCover != nil
        let afterHandOff = openedSteam && steamGamePID != nil
        guard duringCover || afterHandOff else { return }
        for app in NSWorkspace.shared.runningApplications where isSteamFamily(app) {
            if let pid = steamGamePID, app.processIdentifier == pid { continue }
            GameWindow.leaveFullScreen(pid: app.processIdentifier)
            app.hide()
        }
        if duringCover, launchCover?.ready != true {
            claimFrontForLaunchCover()
        }
    }

    /// Keep the Starting cover visible: Steam/Mac/browser activating mid-launch must not bury Mac TV.
    private func keepLaunchCoverInFrontIfNeeded(activated app: NSRunningApplication?) {
        guard let cover = launchCover, !cover.ready, !cover.canceling else { return }
        switch cover.service.kind {
        case .steam, .app, .web: break
        default: return
        }
        // Once we know the game/app PID, fillTV owns focus; don't fight it.
        if let pid = steamGamePID, app?.processIdentifier == pid { return }
        if app?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        if let app, isSteamFamily(app) { suppressSteamUIWhileLaunchingGame(); return }
        // Mac app / browser waking under the cover: hide until hand-off.
        if let app, steamGamePID == nil {
            switch cover.service.kind {
            case .app, .web: app.hide()
            default: break
            }
        }
        claimFrontForLaunchCover()
    }

    /// After hand-off: if Steam (or Mac TV after the cover) jumps forward, put the game back.
    private func keepGameInFrontIfSteamSteals(activated app: NSRunningApplication?) {
        guard let pid = steamGamePID, let app else { return }
        if app.processIdentifier == pid { return }
        // Still showing the cover and waiting for the game — cover logic owns focus.
        if let cover = launchCover, !cover.ready, !cover.canceling, steamWatchUntil != nil { return }
        if isSteamFamily(app) {
            suppressSteamUIWhileLaunchingGame()
            activateExternalApp(pid: pid)
            return
        }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            activateExternalApp(pid: pid)
        }
    }
}

/// Puts a game's window on the TV and in full screen, a few seconds after it opens, the way the
/// green button would. Many games don't allow macOS full screen; their window fills the TV screen
/// below the menu bar instead. Games that already fill the screen are left alone. Needs Accessibility.
enum GameWindow {
    /// Retries until fullscreen succeeds or attempts are exhausted. `completion(true)` on success;
    /// `completion(false)` when retries run out (caller should still dismiss a launch cover).
    /// Without Accessibility trust, returns success after the first delay so the cover cannot stick.
    @MainActor
    static func fillTV(pid: pid_t, screen: NSScreen?, attempt: Int = 0,
                       completion: (@MainActor (Bool) -> Void)? = nil) {
        // Games take a moment to open their window; try a few times.
        let delays: [Double] = [2.5, 4, 6, 10]
        guard attempt < delays.count else {
            completion?(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) {
            MainActor.assumeIsolated {
                if makeFullScreen(pid: pid, on: screen) {
                    completion?(true)
                } else {
                    fillTV(pid: pid, screen: screen, attempt: attempt + 1, completion: completion)
                }
            }
        }
    }

    /// Drop macOS fullscreen on this app's windows (Steam must not sit on the TV during game launch).
    @MainActor
    static func leaveFullScreen(pid: pid_t) {
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary) else { return }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            if bool(window, "AXFullScreen") == true {
                AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
            }
        }
    }

    /// True once the game's window is full screen, or already fills its display.
    /// Also true when Accessibility is off — fullscreen cannot be forced; caller gets a clean hand-off.
    @MainActor
    static func makeFullScreen(pid: pid_t, on screen: NSScreen?) -> Bool {
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else { return true }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], let window = windows.first else { return false }
        if bool(window, "AXFullScreen") == true { return true }
        guard let frame = frame(of: window) else { return false }
        let target = screen ?? NSScreen.screens.first { $0.frame.intersects(flipped(frame)) } ?? NSScreen.main
        guard let target else { return false }
        // A borderless window that already covers the display is the game's own full screen.
        if frame.width >= target.frame.width - 2, frame.height >= target.frame.height - 2 { return true }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? target.frame.height
        if settable(window, "AXFullScreen") {
            // Move it onto the TV first, so full screen happens there.
            if !target.frame.intersects(flipped(frame)) {
                var origin = CGPoint(x: target.frame.minX + 40, y: primaryHeight - target.frame.maxY + 40)
                if let position = AXValueCreate(.cgPoint, &origin) {
                    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
                }
            }
            return AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue) == .success
        }
        // No full screen for this game: fill the TV screen below the menu bar.
        let area = target.visibleFrame
        var origin = CGPoint(x: area.minX, y: primaryHeight - area.maxY)
        var size = area.size
        if let position = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
        guard let extent = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent) == .success
    }

    private static func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &result) == .success && result.boolValue
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    /// The window's frame in Accessibility coordinates (top-left origin).
    private static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    /// Accessibility's top-left frame in AppKit's bottom-left screen coordinates.
    private static func flipped(_ frame: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

/// Steam games' Top Shelf art, decoded once and kept: the Top Shelf asks for it on every redraw,
/// and a library hero can be 3840 pixels wide.
@MainActor
enum SteamShelfArt {
    /// A file that isn't there is remembered too, until `forget` says it changed.
    private static var images: [URL: NSImage?] = [:]

    static func image(at file: URL) -> NSImage? {
        if let known = images[file] { return known }
        let image = decode(file)
        images.updateValue(image, forKey: file)
        return image
    }

    static func forget(_ file: URL) { images.removeValue(forKey: file) }

    private static func decode(_ file: URL) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 3840]
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
