import AppKit

/// Manages remote server links, pairing tokens, remote state snapshots, and client request routing.
@MainActor
final class RemoteCoordinator: ObservableObject {
    weak var tv: TVController?

    @Published private(set) var remoteGuestToken = ""
    @Published private(set) var remoteGuestLinks: [RemoteLink] = []
    @Published private(set) var remoteLinks: [RemoteLink] = []
    var remoteToken = ""
    var pairingGuest = false {
        didSet {
            if pairingGuest != oldValue {
                tv?.objectWillChange.send()
            }
        }
    }

    var remotePort: UInt16 = 0 {
        didSet {
            refreshRemoteURL()
            addressTimer?.invalidate()
            addressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRemoteURL() }
            }
        }
    }

    private var addressTimer: Timer?
    private var startupPairingPending = false
    private var startupPairingVisible = false
    private var phoneConnectedThisLaunch = false

    var phonePaired: Bool {
        get { UserDefaults.standard.bool(forKey: "phonePaired") }
        set { UserDefaults.standard.set(newValue, forKey: "phonePaired") }
    }

    init(tv: TVController? = nil) {
        self.tv = tv
    }

    func refreshRemoteURL() {
        guard remotePort != 0 else { return }
        let code = RemoteServer.pairingCode()
        let guestCode = RemoteServer.guestPairingCode()
        let codeChanged = code != remoteToken || guestCode != remoteGuestToken
        remoteToken = code
        remoteGuestToken = guestCode
        let found: [(label: String, ip: String?)] = [("Same Wi-Fi", LAN.ipv4()), ("Tailscale", LAN.tailscaleIPv4())]
        let addresses = found.compactMap { entry in entry.ip.map { (entry.label, "http://\($0):\(remotePort)") } }
        guard codeChanged || addresses.map(\.1) != remoteLinks.map(\.address) else { return }
        remoteLinks = addresses.map { label, address in
            RemoteLink(label: label, address: address, qr: QRCode.image(for: "\(address)/?k=\(remoteToken)"))
        }
        remoteGuestLinks = addresses.map { label, address in
            RemoteLink(label: label, address: address, qr: QRCode.image(for: "\(address)/?k=\(remoteGuestToken)"))
        }
        tv?.objectWillChange.send()
    }

    func offerStartupPairing() {
        startupPairingPending = !phoneConnectedThisLaunch
        showStartupPairingIfReady()
    }

    func showStartupPairingIfReady() {
        guard let tv, startupPairingPending, !phoneConnectedThisLaunch,
              tv.setup == nil, tv.profilePicker == nil, tv.mode == .launcher else { return }
        startupPairingPending = false
        startupPairingVisible = true
        tv.pairing = true
    }

    func noteRemoteConnection() {
        phoneConnectedThisLaunch = true
        startupPairingPending = false
        if startupPairingVisible, let tv {
            tv.pairing = false
        }
    }

    func notePairingDismissed() {
        startupPairingVisible = false
    }

    // MARK: - Remote State

    func remoteState() -> [String: Any] {
        guard let tv else { return [:] }
        phonePaired = true
        noteRemoteConnection()
        tv.notePhoneDuringSetup()

        let sheetName: String
        switch tv.activeSheet {
        case .setup: sheetName = "setup"
        case .profilePicker: sheetName = "profiles"
        case .playbackCheck: sheetName = "playback-check"
        case .topShelfPreferences: sheetName = "top-shelf"
        case .addApp: sheetName = "add-app"
        case .pairing: sheetName = "pairing"
        case .organizer: sheetName = "arrange-apps"
        case .settings: sheetName = "settings"
        case .controlCenter: sheetName = "control-center"
        case nil: sheetName = ""
        }

        var state: [String: Any] = [
            "device": tv.deviceName,
            "mode": "launcher",
            "apps": tv.arrangedServices.map { service -> [String: Any] in
                ["id": service.id, "name": service.name, "icon": Icons.image(for: service) != nil,
                 "pinned": tv.isPinned(service.id), "canMoveEarlier": tv.canMoveApp(service.id, by: -1),
                 "canMoveLater": tv.canMoveApp(service.id, by: 1)]
            },
            "canRestore": tv.library.hasHiddenBuiltIns,
            "profile": tv.profile.name,
            "focus": String(describing: tv.focus),
            "sheet": sheetName,
            "autoSkip": tv.autoSkip,
            "autoNext": tv.autoNext,
            "keepMacAwake": tv.keepMacAwake,
            "lidOverride": tv.lidOverride,
            "lidStatus": tv.lidStatus,
            "accessibilityAllowed": AXIsProcessTrusted(),
            "sleepMinutes": tv.sleepMinutesLeft,
        ]
        state["displaySetup"] = ["displays": tv.displaySetup, "fullscreen": tv.window?.styleMask.contains(.fullScreen) ?? false]
        state["displaysSleeping"] = tv.displaysSleeping
        state["websitePlayer"] = tv.browserPreferences.choice(for: tv.profile.id).rawValue
        state["braveInstalled"] = tv.braveInstalled

        if tv.externalBrowser != nil {
            state["externalBrowser"] = [
                "name": "Brave",
                "service": tv.externalBrowserService?.name ?? "Website",
                "accessibilityAllowed": AXIsProcessTrusted(),
                "error": tv.externalBrowserError ?? "",
                "opening": tv.externalBrowserOpening
            ]
        }
        if tv.playbackCoordinator.iinaOpen {
            state["mode"] = "player"
            state["externalPlayer"] = ["name": "IINA", "status": tv.iinaPlaybackStatus, "error": tv.iinaPlaybackError ?? ""]
        }
        state["iinaInstalled"] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.colliderli.iina") != nil

        if let movie = tv.currentLocalMovie {
            state["currentLocalMovie"] = ["id": PhoneFiles.id(for: movie.url), "title": movie.displayTitle, "player": tv.localMoviePlayer]
        }
        if case .player(let service) = tv.mode {
            state["mode"] = "player"
            state["current"] = ["id": service.id, "name": service.name]
        } else if tv.mode == .movie, let player = tv.moviePlayer {
            state["mode"] = "player"
            state["current"] = ["id": "movies", "name": player.movie.displayTitle]
            state["movie"] = ["time": player.time, "duration": player.duration, "playing": player.playing,
                              "failure": player.engine.renderFailure ?? ""]
        }
        return state
    }

    // MARK: - Remote Routing

    @discardableResult
    func handleGuestCommand(_ command: RemoteCommand) -> Bool {
        switch command {
        case .home, .playPause, .seek, .volume, .mute, .activateBrowser, .browserFullscreen:
            tv?.handle(command, from: .remote)
            return true
        default: return false
        }
    }

    func handleAppsRequest(_ request: HTTPRequest) -> HTTPResponse? {
        guard let tv else { return nil }
        if let response = tv.handleSharesRequest(request) { return response }
        if let response = tv.handleJellyfinRequest(request) { return response }
        if request.method == "POST", request.path == "/display/select" {
            guard let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                  let id = body["id"] as? String, tv.selectTVDisplay(id: id) else {
                return .json(["error": "Choose a connected display."], status: "400 Bad Request")
            }
            return .json(["ok": true])
        }
        if request.method == "POST", request.path == "/browser/open" {
            guard let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                  let address = body["url"] as? String, let url = WebsiteAddress.url(from: address) else {
                return .json(["error": "Enter an HTTP or HTTPS website address, such as youtube.com."], status: "400 Bad Request")
            }
            guard !tv.externalBrowserOpening else {
                return .json(["error": "Wait for the website to open, then try again."], status: "409 Conflict")
            }
            let service = Service(id: "browser-session", name: url.host ?? "Website", kind: .web(url))
            if tv.browserPreferences.choice(for: tv.profile.id) == .brave, tv.externalBrowser != nil {
                do {
                    try tv.playbackCoordinator.navigateExternalBrowser(service: service, url: url)
                } catch {
                    return .json(["error": error.localizedDescription], status: "409 Conflict")
                }
            } else {
                tv.open(service)
            }
            return .json(["ok": true])
        }
        if request.method == "POST", request.path == "/browser/preference" {
            guard let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                  let raw = body["player"] as? String, tv.setWebsitePlayer(raw) else {
                return .json(["error": "Install Brave to choose it."], status: "400 Bad Request")
            }
            return .json(["ok": true])
        }
        if let response = tv.handleSubtitleRequest(request) ?? tv.handleFilesRequest(request) { return response }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        switch (request.method, request.path) {
        case ("GET", "/macapps"):
            let installed = Set(tv.services.compactMap { service -> String? in
                if case .app(let bundleID) = service.kind { return bundleID }
                return nil
            })
            return .json(InstalledApps.matching(request.query["q"] ?? "").map {
                ["name": $0.name, "bundleID": $0.bundleID, "added": installed.contains($0.bundleID)]
            })
        case ("POST", "/apps/add"):
            let app: AddedApp?
            if let bundleID = body["bundleID"] as? String {
                app = tv.addMacApp(bundleID: bundleID)
            } else if let address = body["url"] as? String {
                app = tv.addWebsite(name: body["name"] as? String, address: address)
            } else {
                app = nil
            }
            guard let app else { return .json(["error": "Couldn't add that. Check the address."], status: "400 Bad Request") }
            return .json(["ok": true, "id": app.id, "name": app.name])
        case ("POST", "/apps/remove"):
            guard let id = body["id"] as? String else { return .json(["error": "Missing app"], status: "400 Bad Request") }
            tv.removeApp(id)
            return .json(["ok": true])
        case ("POST", "/apps/restore"):
            tv.restoreBuiltInApps()
            return .json(["ok": true])
        case ("POST", "/apps/pin"):
            guard let id = body["id"] as? String, let value = body["pinned"] as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID(), tv.arrangedServices.contains(where: { $0.id == id }) else {
                return .json(["error": "Choose an app and whether to pin it."], status: "400 Bad Request")
            }
            guard tv.setPinned(id, value.boolValue) else { return .json(["error": "Couldn't save favourites. Check storage and folder permissions on the Mac."], status: "500 Internal Server Error") }
            return .json(["ok": true])
        case ("POST", "/apps/move"):
            guard let id = body["id"] as? String, let value = body["offset"] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value == -1 || value == 1,
                  tv.canMoveApp(id, by: value.intValue) else {
                return .json(["error": "That app can't move further in this group."], status: "400 Bad Request")
            }
            guard tv.moveApp(id, by: value.intValue) else { return .json(["error": "Couldn't save that app's position. Check storage on the Mac."], status: "500 Internal Server Error") }
            return .json(["ok": true])
        default:
            return nil
        }
    }
}
