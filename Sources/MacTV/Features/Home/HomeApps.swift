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
        Task { [weak self] in
            let png = await IconFinder.icon(forSite: url, name: app.name)
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
            let origin = library
            Task { [weak self] in
                let png = await SteamLibrary.tile(for: game.appID)
                await MainActor.run { self?.useIcon(png, for: app.id, in: origin) }
            }
        }
        return app
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

    func removeApp(_ id: String) {
        guard let service = services.first(where: { $0.id == id }), service.kind != .settings, service.kind != .addApp else { return }
        library.remove(id)
        Icons.forget(id)
        reloadServices()
        showToast("Removed \(service.name)")
    }

    func restoreBuiltInApps() {
        library.restoreBuiltIns()
        reloadServices()
    }


    func iconPNG(for id: String) -> Data? {
        services.first { $0.id == id }.flatMap { Icons.png(for: $0) }
    }
}
