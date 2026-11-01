import AppKit
import SwiftUI
import IOKit.pwr_mgt
import WebKit

enum RemoteCommand {
    enum Direction: String { case up, down, left, right }

    case move(Direction), select, back, home
    case playPause, seek(forward: Bool)
    case volume(Int), mute
    case text(String), deleteBackward
    case pointer(dx: Double, dy: Double), click, scroll(dy: Double)
    case launch(String), openInBrowser
    case screenOff, screenOn, sleepMac
    case sleepTimer(minutes: Int)
    case controlCenter
    case nextControl, previousControl, activateBrowser, browserFullscreen, retryBrowser
    case setting(String, Bool)

    init?(json: [String: Any]) {
        guard let action = json["a"] as? String else { return nil }
        switch action {
        case "up", "down", "left", "right": self = .move(Direction(rawValue: action)!)
        case "ok": self = .select
        case "back": self = .back
        case "home": self = .home
        case "playpause": self = .playPause
        case "rewind": self = .seek(forward: false)
        case "forward": self = .seek(forward: true)
        case "volup": self = .volume(6)
        case "voldown": self = .volume(-6)
        case "mute": self = .mute
        case "text":
            guard let text = json["t"] as? String, !text.isEmpty else { return nil }
            self = .text(String(text.prefix(500)))
        case "backspace": self = .deleteBackward
        case "pointer": self = .pointer(dx: json["dx"] as? Double ?? 0, dy: json["dy"] as? Double ?? 0)
        case "click": self = .click
        case "scroll": self = .scroll(dy: json["dy"] as? Double ?? 0)
        case "launch":
            guard let id = json["id"] as? String else { return nil }
            self = .launch(id)
        case "browser": self = .openInBrowser
        case "screenoff": self = .screenOff
        case "screenon": self = .screenOn
        case "sleep": self = .sleepMac
        case "sleeptimer": self = .sleepTimer(minutes: json["m"] as? Int ?? 0)
        case "controlcenter": self = .controlCenter
        case "nextcontrol": self = .nextControl
        case "previouscontrol": self = .previousControl
        case "activatebrowser": self = .activateBrowser
        case "browserfullscreen": self = .browserFullscreen
        case "retrybrowser": self = .retryBrowser
        case "setting":
            guard let key = json["k"] as? String, let value = json["v"] as? Bool else { return nil }
            self = .setting(key, value)
        default: return nil
        }
    }
}

/// A key press delivered to the web view as if typed on the Mac's keyboard.
struct Key {
    let code: UInt16
    let chars: String
    var flags: NSEvent.ModifierFlags = []

    private static func arrow(_ code: UInt16, _ scalar: Int) -> Key {
        Key(code: code, chars: String(UnicodeScalar(UInt32(scalar))!), flags: [.numericPad, .function])
    }

    static let left = arrow(123, NSLeftArrowFunctionKey)
    static let right = arrow(124, NSRightArrowFunctionKey)
    static let down = arrow(125, NSDownArrowFunctionKey)
    static let up = arrow(126, NSUpArrowFunctionKey)
    static let enter = Key(code: 36, chars: "\r")
    static let escape = Key(code: 53, chars: "\u{1b}")
    static let space = Key(code: 49, chars: " ")
    static let delete = Key(code: 51, chars: "\u{7f}")

    static func direction(_ d: RemoteCommand.Direction) -> Key {
        switch d {
        case .up: up
        case .down: down
        case .left: left
        case .right: right
        }
    }
}

struct RemoteLink: Identifiable {
    let label: String
    let address: String
    let qr: NSImage?
    var id: String { address }
}

@MainActor
final class TVController: NSObject, ObservableObject {
    enum Mode: Equatable {
        case launcher
        case player(Service)
        /// A movie from the Movies app, in Mac TV's own player.
        case movie
    }

    /// What has focus on the home screen: an app tile, an item in the Top Shelf, or a pill in the
    /// status row at the top right.
    enum Focus: Equatable {
        case app(Int)
        case shelf(Int)
        case status(StatusItem)
    }

    /// The status row's pills that take focus, left to right; the clock doesn't.
    enum StatusItem: Equatable {
        case lid, controlCenter, profile
    }

    var statusItems: [StatusItem] {
        (lidSleepOff ? [.lid] : []) + [.controlCenter, .profile]
    }

    enum SheetDestination: Int, Identifiable, Equatable, Comparable, CaseIterable {
        case controlCenter = 0
        case settings
        case organizer
        case pairing
        case addApp
        case topShelfPreferences
        case playbackCheck
        case profilePicker
        case setup

        var id: Int { rawValue }

        static func < (lhs: SheetDestination, rhs: SheetDestination) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - Dedicated Coordinators

    let playbackCoordinator: PlaybackCoordinator
    let remoteCoordinator: RemoteCoordinator
    let displayCoordinator: DisplayCoordinator

    // MARK: - State

    @Published private(set) var mode: Mode = .launcher
    @Published private(set) var focus: Focus = .app(0)
    /// Suppresses mouse hover focus changes during scrolling or keyboard navigation until the pointer actually moves.
    var suppressHover = false
    /// The top-row app whose content the Top Shelf shows.
    @Published private(set) var shelfAppIndex = 0
    /// Pointer position over the focused tile, -0.5…0.5 on each axis, for the parallax tilt.
    @Published var tilt: CGSize = .zero
    @Published var pairing = false {
        didSet {
            if pairing {
                if !oldValue {
                    remoteCoordinator.pairingGuest = false
                    displayCoordinator.resetPairingFocus()
                }
                refreshRemoteURL()
            } else {
                remoteCoordinator.notePairingDismissed()
            }
        }
    }

    /// The Settings sheet on the TV, while it's open.
    @Published var settings: SettingsPanel?
    /// Arrange apps with the keyboard, game controller or phone's D-pad.
    @Published var organizer: AppOrganizer?
    @Published var playbackCheck: PlaybackDiagnostics?
    @Published var topShelfPreferences: TopShelfPreferencesPanel?
    @Published var playerFailure: PlayerFailure?
    /// The add-app sheet on the TV, while it's open.
    @Published var adder: AppAdder?
    /// The Movies app's screen, while it's open.
    @Published var movies: MoviesBrowser?
    /// First-run setup, while it's showing.
    @Published var setup: SetupFlow?
    /// Control Center, while it's open.
    @Published var controlCenter: ControlCenterPanel?
    /// The "Who's watching?" screen, while it's showing.
    @Published var profilePicker: ProfilePicker?
    /// Who's watching: their apps and their sign-ins.
    @Published var profile: Profile

    /// Shown after a few idle minutes on the home screen; any input dismisses it.
    @Published private(set) var screensaver = false
    @Published private(set) var sleepAt: Date?
    /// The focused button on Mac TV's own Brave screen.
    @Published var browserFocus = 0
    let browserPreferences: BrowserPreferences
    @Published private(set) var toast: String?
    /// The volume indicator, shown for a moment after the remote changes the volume.
    @Published private(set) var volume: VolumeLevel?
    /// The connected game controller, if any.
    @Published var controller: ControllerInfo?
    /// A controller connecting or disconnecting, shown for a moment.
    @Published private(set) var controllerNotice: ControllerNotice?

    /// The home screen's apps, in order; changes when the user adds or removes apps.
    @Published private(set) var services: [Service] = []
    let profiles: ProfileStore
    var library: AppLibrary
    let columns = 6
    let deviceName = Host.current().localizedName ?? "Mac"
    weak var window: NSWindow?

    /// Press the players' own Skip Intro / Skip Recap buttons.
    var autoSkip: Bool {
        get { UserDefaults.standard.bool(forKey: "autoSkip") }
        set { UserDefaults.standard.set(newValue, forKey: "autoSkip") }
    }

    /// Press Next Episode when the player offers it.
    var autoNext: Bool {
        get { UserDefaults.standard.bool(forKey: "autoNext") }
        set { UserDefaults.standard.set(newValue, forKey: "autoNext") }
    }

    // MARK: - Forwarded Properties to Coordinators

    // Playback
    var webView: WKWebView? { playbackCoordinator.webView }
    var moviePlayer: MoviePlayer? { playbackCoordinator.moviePlayer }
    var currentLocalMovie: Movie? { playbackCoordinator.currentLocalMovie }
    var localMoviePlayer: String { playbackCoordinator.localMoviePlayer }
    var iinaPlaybackError: String? { playbackCoordinator.iinaPlaybackError }
    var iinaPlaybackStatus: String { playbackCoordinator.iinaPlaybackStatus }
    var externalBrowser: BraveSession? { playbackCoordinator.externalBrowser }
    var externalBrowserService: Service? { playbackCoordinator.externalBrowserService }
    var externalBrowserError: String? { playbackCoordinator.externalBrowserError }
    var externalBrowserOpening: Bool { playbackCoordinator.externalBrowserOpening }

    // Remote
    var remoteToken: String {
        get { remoteCoordinator.remoteToken }
        set { remoteCoordinator.remoteToken = newValue }
    }
    var remoteGuestToken: String { remoteCoordinator.remoteGuestToken }
    var remoteLinks: [RemoteLink] { remoteCoordinator.remoteLinks }
    var remoteGuestLinks: [RemoteLink] { remoteCoordinator.remoteGuestLinks }
    var remotePort: UInt16 {
        get { remoteCoordinator.remotePort }
        set { remoteCoordinator.remotePort = newValue }
    }
    var pairingGuest: Bool {
        get { remoteCoordinator.pairingGuest }
        set { remoteCoordinator.pairingGuest = newValue }
    }
    var phonePaired: Bool {
        get { remoteCoordinator.phonePaired }
        set { remoteCoordinator.phonePaired = newValue }
    }

    // Display & Power
    var power: PowerStatus { displayCoordinator.power }
    var lidSleepOff: Bool { displayCoordinator.lidSleepOff }
    var displaysSleeping: Bool { displayCoordinator.displaysSleeping }
    var keepMacAwake: Bool {
        get { displayCoordinator.keepMacAwake }
        set { displayCoordinator.keepMacAwake = newValue }
    }
    var lidOverride: Bool {
        get { displayCoordinator.lidOverride }
        set { displayCoordinator.lidOverride = newValue }
    }
    var lidStatus: String { displayCoordinator.lidStatus }
    var playbackScreen: NSScreen? { displayCoordinator.playbackScreen }

    // MARK: - Forwarded Methods

    func offerStartupPairing() { remoteCoordinator.offerStartupPairing() }
    func showStartupPairingIfReady() { remoteCoordinator.showStartupPairingIfReady() }
    func noteRemoteConnection() { remoteCoordinator.noteRemoteConnection() }
    func refreshRemoteURL() { remoteCoordinator.refreshRemoteURL() }
    func remoteState() -> [String: Any] { remoteCoordinator.remoteState() }
    func handleAppsRequest(_ request: HTTPRequest) -> HTTPResponse? { remoteCoordinator.handleAppsRequest(request) }
    func handleGuestCommand(_ command: RemoteCommand) -> Bool { remoteCoordinator.handleGuestCommand(command) }

    func startPowerManagement() { displayCoordinator.startPowerManagement() }
    func stopPowerManagement() { displayCoordinator.stopPowerManagement() }
    func refreshPower() { displayCoordinator.refreshPower() }
    func noteDisplaySleep(_ sleeping: Bool) { displayCoordinator.noteDisplaySleep(sleeping) }
    func wakeDisplays() { displayCoordinator.wakeDisplays() }

    @discardableResult
    func playInIINA(_ movie: Movie, subtitle: URL? = nil) -> Bool {
        guard let screen = playbackScreen else { showToast("Connect the display for movie playback."); return false }
        return playbackCoordinator.playInIINA(movie, subtitle: subtitle, position: nil, screen: screen)
    }
    func closeIINAPlayback(terminating: Bool = false) { playbackCoordinator.closeIINAPlayback(terminating: terminating) }
    func searchIINASubtitles() -> Bool { playbackCoordinator.searchIINASubtitles() }
    func playMovie(_ movie: Movie, from seconds: Double) { playbackCoordinator.playMovie(movie, from: seconds) }
    func closeMovie() { playbackCoordinator.closeMovie() }
    func retryExternalBrowser() { playbackCoordinator.retryExternalBrowser() }
    func activateExternalBrowser() { playbackCoordinator.activateExternalBrowser() }
    func closeExternalBrowser() { playbackCoordinator.closeExternalBrowser() }

    // MARK: - Sheet Router State

    var activeSheet: SheetDestination? {
        if setup != nil { return .setup }
        if profilePicker != nil { return .profilePicker }
        if playbackCheck != nil { return .playbackCheck }
        if topShelfPreferences != nil { return .topShelfPreferences }
        if adder != nil { return .addApp }
        if pairing { return .pairing }
        if organizer != nil { return .organizer }
        if settings != nil { return .settings }
        if controlCenter != nil { return .controlCenter }
        return nil
    }

    func isTopSheet(_ destination: SheetDestination) -> Bool {
        activeSheet == destination && !screensaver
    }

    // MARK: - Private State

    private var toastTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var controllerInput: ControllerInput?
    private var launchedAppID: String?
    /// A Steam game just launched from Mac TV: watched so Mac TV comes back when it quits.
    var steamWatchUntil: Date?
    var steamGamePID: pid_t?
    /// Mac TV opened Steam or a Steam game, so remote presses may go to it.
    var openedSteam = false
    var steamObservers: [NSObjectProtocol] = []
    var pointer: CGPoint?
    private var sleepTimer: Timer?
    private var idleTimer: Timer?
    private var lastActivity = Date()

    // MARK: - Lifecycle

    override convenience init() {
        let store = ProfileStore()
        self.init(library: AppLibrary(profileID: store.current.id), profiles: store)
    }

    init(library: AppLibrary, profiles: ProfileStore? = nil, browserPreferences: BrowserPreferences? = nil) {
        self.browserPreferences = browserPreferences ?? BrowserPreferences()
        let store = profiles ?? ProfileStore(folder: library.storageFolder)
        self.profiles = store
        self.profile = store.current
        self.library = library
        let pc = PlaybackCoordinator()
        let rc = RemoteCoordinator()
        let dc = DisplayCoordinator()
        self.playbackCoordinator = pc
        self.remoteCoordinator = rc
        self.displayCoordinator = dc
        super.init()
        pc.tv = self
        rc.tv = self
        dc.tv = self
        UserDefaults.standard.register(defaults: ["autoSkip": true, "autoNext": true, "keepMacAwake": true])
        services = library.services()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
    }

    // MARK: - Screensaver and sleep timer

    /// Any keyboard, mouse or remote input. Returns true when it only woke the screensaver.
    @discardableResult
    func noteActivity() -> Bool {
        lastActivity = Date()
        guard screensaver else { return false }
        screensaver = false
        return true
    }

    private func checkIdle() {
        if mode == .launcher, !playbackCoordinator.isAnyPlaybackActive, !displaysSleeping,
           activeSheet == nil, movies == nil, !screensaver,
           Date().timeIntervalSince(lastActivity) > TimeInterval(ScreenSaverSettings.delayMinutes * 60) {
            showScreensaver()
        }
    }

    func showScreensaver() {
        guard !displaysSleeping else { return }
        Analytics.send(.screenSaverStarted, ["wallpaper": ScreenSaverSettings.wallpaper.rawValue])
        ScreenSaverSettings.playing = ScreenSaverSettings.pictures(for: ScreenSaverSettings.wallpaper)
        lastActivity = Date()
        screensaver = true
    }

    /// Stops playback, goes home and turns the screen off after `minutes`; 0 cancels.
    func setSleepTimer(minutes: Int) {
        sleepTimer?.invalidate()
        guard minutes > 0 else {
            sleepAt = nil
            showToast("Sleep timer off")
            return
        }
        sleepAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleepAt = nil
                self.goHome()
                self.displayCoordinator.noteDisplaySleep(true)
                SystemControl.displayOff()
            }
        }
        showToast("Sleep timer: \(minutes) minutes")
    }

    // MARK: - Adding and removing apps

    func reloadServices() {
        let oldFocus = focus
        let shelfID = services.indices.contains(shelfAppIndex) ? services[shelfAppIndex].id : nil
        let focusedID: String?
        if case .app(let index) = focus, services.indices.contains(index) { focusedID = services[index].id }
        else { focusedID = shelfID }
        services = library.services()
        if let index = services.firstIndex(where: { $0.id == shelfID }), index < columns { shelfAppIndex = index }
        else { shelfAppIndex = 0 }
        let newIndex = services.firstIndex { $0.id == focusedID }
        switch oldFocus {
        case .app(let index):
            let next = newIndex ?? min(index, max(services.count - 1, 0))
            setFocus(.app(next))
            if next < columns { shelfAppIndex = next }
        case .shelf(let index):
            if let newIndex, newIndex < columns, shelfCount > 0 {
                setFocus(.shelf(min(index, shelfCount - 1)))
            } else {
                setFocus(.app(newIndex ?? shelfAppIndex))
            }
        case .status(let item):
            if !statusItems.contains(item) { setFocus(.status(.controlCenter)) }
        }
        reconcileOrganizerSelection()
    }

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

    // MARK: - Home screen focus

    var shelfService: Service { services.indices.contains(shelfAppIndex) ? services[shelfAppIndex] : services[0] }

    /// True when focus is below the top row; the Top Shelf scrolls away.
    var inGrid: Bool {
        if case .app(let index) = focus { return index >= columns }
        return false
    }

    /// How many things in the Top Shelf can take focus: its Open button, for apps.
    var shelfCount: Int {
        switch shelfService.kind {
        case .web, .app, .steam, .movies: return TopShelfFeed.shared.searchURL(for: shelfService) == nil ? 1 : 2
        case .addApp, .settings: return 0
        }
    }

    func setFocus(_ newFocus: Focus) {
        guard newFocus != focus else { return }
        focus = newFocus
        tilt = .zero
        if case .app(let index) = newFocus, index < columns { shelfAppIndex = index }
    }

    func hover(_ index: Int, tilt: CGSize) {
        guard !suppressHover else { return }
        switch focus {
        case .shelf, .status: return
        case .app: break
        }
        let inTopShelfNow = !inGrid
        let targetInTopShelf = index < columns
        guard inTopShelfNow == targetInTopShelf else { return }
        if index < services.count {
            if focus != .app(index) { setFocus(.app(index)) }
            self.tilt = tilt
        }
    }

    private func moveFocus(_ direction: RemoteCommand.Direction) {
        switch focus {
        case .app(let index):
            let row = index / columns, column = index % columns
            switch direction {
            case .left:
                if column > 0 { setFocus(.app(index - 1)) }
            case .right:
                if column < columns - 1, index + 1 < services.count { setFocus(.app(index + 1)) }
            case .down:
                if index + columns < services.count {
                    setFocus(.app(index + columns))
                } else if (row + 1) * columns < services.count {
                    setFocus(.app(services.count - 1))
                }
            case .up:
                if row > 0 {
                    setFocus(.app(index - columns))
                } else if shelfCount > 0 {
                    setFocus(.shelf(0))
                } else {
                    setFocus(.status(.controlCenter))
                }
            }
        case .shelf(let index):
            switch direction {
            case .left: if index > 0 { setFocus(.shelf(index - 1)) }
            case .right: if index + 1 < shelfCount { setFocus(.shelf(index + 1)) }
            case .down: setFocus(.app(shelfAppIndex))
            case .up: setFocus(.status(.controlCenter))
            }
        case .status(let item):
            let items = statusItems
            let index = items.firstIndex(of: item) ?? items.firstIndex(of: .controlCenter) ?? 0
            switch direction {
            case .left: setFocus(.status(items[max(0, index - 1)]))
            case .right: setFocus(.status(items[min(items.count - 1, index + 1)]))
            case .down: setFocus(shelfCount > 0 ? .shelf(0) : .app(shelfAppIndex))
            case .up: break
            }
        }
    }

    func activateStatus(_ item: StatusItem) {
        setFocus(.status(item))
        switch item {
        case .lid: settings = SettingsPanel(section: .power, open: true, row: 1)
        case .controlCenter: openControlCenter()
        case .profile: openProfiles()
        }
    }

    func activateShelf(_ index: Int) {
        if index == 0, let url = TopShelfFeed.shared.searchURL(for: shelfService) {
            playbackCoordinator.playWeb(shelfService, url: url)
        } else {
            open(shelfService)
        }
    }

    private func handleInLauncher(_ command: RemoteCommand) {
        if setup != nil { handleSetup(command); return }
        if profilePicker != nil { handleProfiles(command); return }
        if playbackCheck != nil { switch command { case .back, .select: playbackCheck = nil; default: break }; return }
        if topShelfPreferences != nil { handleTopShelfPreferences(command); return }
        if adder != nil { handleAdder(command); return }
        if pairing { handlePairing(command); return }
        if organizer != nil { handleOrganizer(command); return }
        if settings != nil { handleSettings(command); return }
        if controlCenter != nil { handleControlCenter(command); return }
        if movies != nil {
            handleMovies(command)
            return
        }
        switch command {
        case .move(let direction): moveFocus(direction)
        case .select:
            switch focus {
            case .app(let index): if services.indices.contains(index) { open(services[index]) }
            case .shelf(let index): activateShelf(index)
            case .status(let item): activateStatus(item)
            }
        case .back:
            switch focus {
            case .status: setFocus(shelfCount > 0 ? .shelf(0) : .app(shelfAppIndex))
            case .shelf: setFocus(.app(shelfAppIndex))
            case .app: if inGrid { setFocus(.app(0)) }
            }
        case .pointer(let dx, let dy): movePointer(dx: dx, dy: dy)
        case .click: clickPointer()
        default: break
        }
    }

    private var feedbackState: String {
        String(describing: (focus, setup, profilePicker, controlCenter, settings, organizer, playbackCheck, topShelfPreferences, adder, movies, pairing, mode == .launcher))
    }

    func iconPNG(for id: String) -> Data? {
        services.first { $0.id == id }.flatMap { Icons.png(for: $0) }
    }

    // MARK: - Command Dispatch

    func handle(_ command: RemoteCommand, from source: Feedback.Source = .keyboard) {
        if source == .remote {
            noteRemoteConnection()
            if displaysSleeping {
                switch command {
                case .screenOff, .screenOn, .sleepMac: break
                default: wakeDisplays()
                }
            }
        }
        let dismissedScreensaver = noteActivity()
        switch command {
        case .screenOff, .screenOn, .sleepMac: break
        default: if dismissedScreensaver { return }
        }
        Analytics.noteInput(source)

        switch command {
        case .pointer, .click, .scroll: break
        default:
            NSCursor.setHiddenUntilMouseMoves(true)
            suppressHover = true
        }

        switch command {
        case .home: goHome(); return
        case .activateBrowser:
            if playbackCoordinator.iinaRunning {
                playbackCoordinator.handleIINACommand(command)
            } else { activateExternalBrowser() }
            return
        case .retryBrowser:
            retryExternalBrowser()
            return
        case .launch(let id):
            if let service = services.first(where: { $0.id == id }) { open(service) }
            return
        case .volume(let delta):
            if playbackCoordinator.iinaRunning { playbackCoordinator.handleIINACommand(command) }
            else { showVolume(SystemControl.changeVolume(by: delta)) }
            return
        case .mute:
            if playbackCoordinator.iinaRunning { playbackCoordinator.handleIINACommand(command) }
            else { showVolume(SystemControl.toggleMute()) }
            return
        case .screenOff:
            displayCoordinator.noteDisplaySleep(true)
            SystemControl.displayOff()
            return
        case .screenOn: wakeDisplays(); return
        case .sleepTimer(let minutes): setSleepTimer(minutes: minutes); return
        case .setting(let key, let value):
            if key == "autoSkip" { autoSkip = value }
            if key == "autoNext" { autoNext = value }
            if key == "keepMacAwake" { keepMacAwake = value }
            if key == "lidOverride" { lidOverride = value }
            objectWillChange.send()
            return
        case .sleepMac:
            goHome()
            SystemControl.sleepNow()
            return
        case .controlCenter:
            guard setup == nil, profilePicker == nil else { return }
            if controlCenter != nil {
                controlCenter = nil
            } else {
                if mode != .launcher || movies != nil { goHome() }
                settings = nil
                organizer = nil
                playbackCheck = nil
                topShelfPreferences = nil
                pairing = false
                adder = nil
                openControlCenter()
            }
            return
        default: break
        }

        if playbackCoordinator.externalBrowser != nil {
            if NSApp.isActive {
                switch command {
                case .move, .select, .back: handleBrowserScreen(command); return
                default: break
                }
            }
            playbackCoordinator.handleExternalBrowserCommand(command)
            return
        }

        if playbackCoordinator.iinaRunning {
            playbackCoordinator.handleIINACommand(command)
            return
        }

        if !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier == launchedAppID
            || (openedSteam && (front.bundleIdentifier == SteamLibrary.bundleID || front.processIdentifier == steamGamePID)) {
            forwardToFrontApp(command)
            return
        }

        if source == .remote || source == .controller, !NSApp.isActive {
            bringToFront()
        }

        switch mode {
        case .launcher:
            let before = feedbackState
            handleInLauncher(command)
            let changed = feedbackState != before
            switch command {
            case .move where changed: Feedback.shared.play(.move, from: source)
            case .select: Feedback.shared.play(.select, from: source)
            case .back where changed: Feedback.shared.play(.back, from: source)
            default: break
            }
        case .player(let service): playbackCoordinator.handleInPlayer(command, service: service)
        case .movie: playbackCoordinator.handleInMovie(command)
        }
    }

    // MARK: - Opening & Home

    func open(_ service: Service) {
        playbackCoordinator.closeIINAPlayback()
        playbackCoordinator.closeExternalBrowser()
        var opened = ["app": analyticsAppName(service)]
        if case .web = service.kind { opened["player"] = browserPreferences.choice(for: profile.id).rawValue }
        Analytics.send(.appOpened, opened)
        playbackCoordinator.resetPlaybackRequest()
        settings = nil
        pairing = false
        adder = nil
        organizer = nil
        playbackCheck = nil
        topShelfPreferences = nil
        switch service.kind {
        case .web(let url):
            playbackCoordinator.playWeb(service, url: url)
        case .app(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            launchedAppID = bundleID
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .steam(let appID):
            NSWorkspace.shared.open(SteamLibrary.launchURL(for: appID))
            openedSteam = true
            if appID != SteamLibrary.bigPicture.appID { watchForSteamGame() }
            showToast("Opening \(service.name) in Steam")
        case .movies:
            openMovies()
        case .addApp:
            adder = AppAdder()
        case .settings:
            openSettings()
        }
    }

    func goHome() {
        playbackCoordinator.closeIINAPlayback()
        playbackCoordinator.closeExternalBrowser()
        playbackCoordinator.resetPlaybackRequest()
        playbackCoordinator.clearCurrentLocalMovie()
        playbackCoordinator.stopMoviePlayer()
        movies = nil
        playbackCoordinator.closeWebPlayback()
        mode = .launcher
        pairing = false
        settings = nil
        organizer = nil
        playbackCheck = nil
        topShelfPreferences = nil
        playerFailure = nil
        controlCenter = nil
        pointer = nil
        launchedAppID = nil
        displayCoordinator.releasePlaybackKeepAwake()
        bringToFront()
    }

    var idleForUpdate: Bool {
        (screensaver || displaysSleeping) && mode == .launcher && setup == nil && !playbackCoordinator.isAnyPlaybackActive
    }

    var braveInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.brave.Browser") != nil }
    var websitePlayerName: String { browserPreferences.choice(for: profile.id) == .brave ? "Brave" : "Built-in" }

    @discardableResult
    func setWebsitePlayer(_ raw: String) -> Bool {
        guard let choice = BrowserChoice(rawValue: raw), choice != .brave || braveInstalled else { return false }
        browserPreferences.setChoice(choice, for: profile.id)
        objectWillChange.send()
        return true
    }

    func stepWebsitePlayer() {
        let next = browserPreferences.choice(for: profile.id) == .embedded ? BrowserChoice.brave : .embedded
        if !setWebsitePlayer(next.rawValue) { showToast("Install Brave Browser to select it.") }
    }

    // MARK: - Helpers for Coordinators

    func setMode(_ newMode: Mode) { mode = newMode }
    func clearPointer() { pointer = nil }
    func setLaunchedAppID(_ id: String?) { launchedAppID = id }
    func openMoviesBrowserOnly() { movies = MoviesBrowser() }
    func reconcileMovieBrowserPosition(for path: String) {
        for (row, line) in movieRows.enumerated() {
            if let column = line.items.firstIndex(of: .movie(path)) {
                movies?.row = row
                movies?.column = column
                break
            }
        }
    }
    func screensaverOff() { screensaver = false }

    // MARK: - Touchpad & Pointer

    func movePointer(dx: Double, dy: Double) {
        guard let window, let bounds = window.contentView?.bounds else { return }
        var point = pointer ?? CGPoint(x: bounds.midX, y: bounds.midY)
        point.x = min(max(point.x + dx, 0), bounds.width - 1)
        point.y = min(max(point.y - dy, 0), bounds.height - 1)
        pointer = point

        let onScreen = window.convertPoint(toScreen: point)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.x, y: primaryHeight - onScreen.y))
        NSCursor.setHiddenUntilMouseMoves(false)
        postMouse(.mouseMoved, at: point)
    }

    func clickPointer() {
        guard let window, let bounds = window.contentView?.bounds else { return }
        let point = pointer ?? CGPoint(x: bounds.midX, y: bounds.midY)
        postMouse(.leftMouseDown, at: point)
        postMouse(.leftMouseUp, at: point)
    }

    private func postMouse(_ type: NSEvent.EventType, at point: CGPoint) {
        guard let window, let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
            pressure: type == .leftMouseDown ? 1 : 0)
        else { return }
        window.sendEvent(event)
    }

    // MARK: - Mac apps & Steam

    private func forwardToFrontApp(_ command: RemoteCommand) {
        let code: CGKeyCode
        switch command {
        case .move(.left): code = 123
        case .move(.right): code = 124
        case .move(.down): code = 125
        case .move(.up): code = 126
        case .select: code = 36
        case .back: code = 53
        case .playPause: code = 49
        case .deleteBackward: code = 51
        case .text(let text):
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            for character in text {
                var units = Array(String(character).utf16)
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                    event.postToPid(pid)
                }
            }
            return
        default: return
        }
        SystemControl.postKeyToFrontApp(code)
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func showVolume(_ level: VolumeLevel) {
        withAnimation(.smooth(duration: 0.3)) { volume = level }
        volumeTask?.cancel()
        volumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { withAnimation(.smooth(duration: 0.4)) { self?.volume = nil } }
        }
    }

    func startControllers() {
        controllerInput = ControllerInput(tv: self)
        controllerInput?.start()
        if ProcessInfo.processInfo.environment["MACTV_PREVIEW_CONTROLLER"] == "1" {
            controllerChanged(ControllerInfo(name: "DualSense Wireless Controller", battery: 0.7, selectSymbol: "xmark.circle",
                                             backSymbol: "circle.circle", menuSymbol: "line.3.horizontal.circle"), connected: true)
        }
    }

    func showControllerNotice(_ notice: ControllerNotice) {
        withAnimation(.smooth(duration: 0.35)) { controllerNotice = notice }
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { withAnimation(.smooth(duration: 0.4)) { self?.controllerNotice = nil } }
        }
    }

    func showToast(_ message: String) {
        withAnimation(.smooth(duration: 0.3)) { toast = message }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { withAnimation(.smooth(duration: 0.4)) { self?.toast = nil } }
        }
    }
}
