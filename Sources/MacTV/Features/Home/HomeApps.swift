import AppKit

// The home screen's apps: adding, removing, pinning and arranging them.
extension TVController {
    var arrangedServices: [Service] { services.filter { $0.kind != .addApp && $0.kind != .settings } }

    func isPinned(_ id: String) -> Bool { library.isPinned(id) }

    @discardableResult
    func setPinned(_ id: String, _ pinned: Bool) -> Bool {
        guard library.setPinned(id, pinned) else { showToast("Couldn't save favourites. Check available storage and folder permissions."); return false }
        reloadServices()
        return true
    }

    func canMoveApp(_ id: String, by offset: Int) -> Bool {
        guard offset == -1 || offset == 1 else { return false }
        let group = arrangedServices.filter { isPinned($0.id) == isPinned(id) }
        guard let index = group.firstIndex(where: { $0.id == id }) else { return false }
        return group.indices.contains(index + offset)
    }

    @discardableResult
    func moveApp(_ id: String, by offset: Int) -> Bool {
        guard library.move(id, by: offset) else { showToast("Couldn't save that app's position."); return false }
        reloadServices()
        return true
    }

    /// Adds a website. Its tile appears at once; the official icon follows when found.
    func addWebsite(name: String?, address: String) -> AddedApp? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host(), host.contains(".") else { return nil }
        let fallbackName = host.replacingOccurrences(of: "www.", with: "").split(separator: ".").first.map {
            $0.prefix(1).uppercased() + $0.dropFirst()
        } ?? host
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let app = library.add(name: trimmed.isEmpty ? fallbackName : trimmed, url: url, bundleID: nil)
        reloadServices()
        showToast("Added \(app.name)")
        let origin = library
        let preset = Catalog.websiteSuggestions.first {
            guard case .web(let known) = $0.kind else { return false }
            return known.host()?.lowercased().replacingOccurrences(of: "www.", with: "")
                == host.lowercased().replacingOccurrences(of: "www.", with: "")
        }
        Task { [weak self] in
            let png = await IconFinder.icon(forSite: url,
                                           name: preset?.iconQuery ?? preset?.name ?? app.name,
                                           regions: preset?.regions)
            await MainActor.run { self?.useIcon(png, for: app.id, in: origin) }
        }
        return app
    }

    func addMacApp(bundleID: String) -> AddedApp? {
        guard let installed = InstalledApps.all.first(where: { $0.bundleID == bundleID }) else { return nil }
        if let existing = services.first(where: { $0.kind == .app(bundleID: bundleID) }) {
            showToast("\(existing.name) is already on the home screen")
            return nil
        }
        let app = library.add(name: installed.name, url: nil, bundleID: bundleID)
        useIcon(IconFinder.icon(forAppAt: installed.path), for: app.id)
        showToast("Added \(app.name)")
        return app
    }

    /// Adds a Steam game (or Steam Big Picture). Its tile appears at once; Steam's artwork follows.
    func addSteamGame(_ game: SteamLibrary.Game) -> AddedApp? {
        if let existing = services.first(where: { $0.kind == .steam(appID: game.appID) }) {
            showToast("\(existing.name) is already on the home screen")
            return nil
        }
        let app = library.add(name: game.name, url: nil, bundleID: nil, steamID: game.appID)
        reloadServices()
        showToast("Added \(app.name)")
        if game == SteamLibrary.bigPicture {
            useIcon(SteamLibrary.appURL.flatMap { IconFinder.icon(forAppAt: $0.path) }, for: app.id)
        } else {
            Task { await fetchSteamArt(appID: game.appID, id: app.id, in: library) }
        }
        return app
    }

    /// Downloads missing Steam tile / Top Shelf art for games already on the dock.
    func ensureSteamHeroes() {
        let origin = library
        for service in services {
            guard case .steam(let appID) = service.kind, appID != SteamLibrary.bigPicture.appID else { continue }
            let tileMissing = !FileManager.default.fileExists(atPath: origin.iconFile(for: service.id).path)
            let heroMissing = !FileManager.default.fileExists(atPath: origin.heroFile(for: service.id).path)
            guard tileMissing || heroMissing else { continue }
            Task { await fetchSteamArt(appID: appID, id: service.id, in: origin, tile: tileMissing) }
        }
    }

    /// Adds shelf-art samples if needed and (re)downloads tile + hero for each.
    func seedSteamShelfSamples() async {
        for game in SteamLibrary.shelfArtSamples {
            let id: String
            if let existing = services.first(where: { $0.kind == .steam(appID: game.appID) }) {
                id = existing.id
            } else {
                let app = library.add(name: game.name, url: nil, bundleID: nil, steamID: game.appID)
                reloadServices()
                id = app.id
            }
            await fetchSteamArt(appID: game.appID, id: id, in: library)
        }
    }

    @discardableResult
    private func fetchSteamArt(appID: String, id: String, in origin: AppLibrary, tile: Bool = true) async -> Bool {
        async let tilePNG: Data? = tile ? SteamLibrary.tile(for: appID) : nil
        async let heroJPEG = SteamLibrary.hero(for: appID)
        let (png, hero) = await (tilePNG, heroJPEG)
        return await MainActor.run {
            guard origin.containsAddedApp(id) else { return false }
            if let png { useIcon(png, for: id, in: origin) }
            if let hero {
                origin.setHero(hero, for: id)
                if origin === library { objectWillChange.send() }
            }
            return png != nil || hero != nil
        }
    }

    func useIcon(_ png: Data?, for id: String, in origin: AppLibrary? = nil) {
        let target = origin ?? library
        guard target.containsAddedApp(id) else { return }
        if let png, let image = NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            target.setIcon(png, accent: TileArt.brandColor(from: image), for: id)
        }
        Icons.forget(id)
        if target === library { reloadServices() }
    }

    /// False when the app isn't one that can be removed, or the change couldn't be saved.
    @discardableResult
    func removeApp(_ id: String) -> Bool {
        guard let service = arrangedServices.first(where: { $0.id == id }) else { return false }
        guard library.remove(id) else {
            showToast("Couldn't remove \(service.name). Check available storage and folder permissions.")
            return false
        }
        Icons.forget(id)
        reloadServices()
        showToast("Removed \(service.name)")
        return true
    }

    func iconPNG(for id: String) -> Data? {
        services.first { $0.id == id }.flatMap { Icons.png(for: $0) }
    }
}
