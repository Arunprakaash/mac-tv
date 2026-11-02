import AppKit
import Combine
import SwiftUI
import WebKit

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

    // MARK: - Dedicated Coordinators

    let playbackCoordinator: PlaybackCoordinator
    let remoteCoordinator: RemoteCoordinator
    let displayCoordinator: DisplayCoordinator
    let audioCoordinator: AudioCoordinator
    let idleCoordinator = IdleCoordinator()
    let preferences = Preferences.shared
    private var coordinatorChanges: [AnyCancellable] = []

    // MARK: - State

    @Published private(set) var mode: Mode = .launcher
    @Published private(set) var focus: Focus = .app(0)
    /// Suppresses mouse hover focus changes during scrolling or keyboard navigation until the pointer actually moves.
    var suppressHover = false
    /// The top-row app whose content the Top Shelf shows.
    @Published private(set) var shelfAppIndex = 0
    /// Pointer position over the focused tile, -0.5…0.5 on each axis, for the parallax tilt. Kept
    /// in its own object, so the pointer moving redraws the tiles, not every view watching the TV.
    let pointerTilt = PointerTilt()
    var tilt: CGSize {
        get { pointerTilt.value }
        set { if pointerTilt.value != newValue { pointerTilt.value = newValue } }
    }
    /// The sheets open over the home screen.
    @Published var sheets = SheetStack() {
        didSet { if sheets.pairing != oldValue.pairing { pairingChanged() } }
    }
    @Published var playerFailure: PlayerFailure?
    /// The Movies app's screen, while it's open.
    @Published var movies: MoviesBrowser?
    /// Who's watching: their apps and their sign-ins.
    @Published var profile: Profile

    /// The focused button on Mac TV's own Brave screen.
    @Published var browserFocus = 0
    let browserPreferences: BrowserPreferences
    /// Toasts, the volume indicator and controller banners.
    let notices = Notices()
    /// The connected game controller, if any.
    @Published var controller: ControllerInfo?

    /// The home screen's apps, in order; changes when the user adds or removes apps.
    @Published private(set) var services: [Service] = []
    let profiles: ProfileStore
    var library: AppLibrary
    let columns = 6
    let deviceName = Host.current().localizedName ?? "Mac"
    weak var window: NSWindow?

    /// Press the players' own Skip Intro / Skip Recap buttons.
    var autoSkip: Bool {
        get { preferences.autoSkip }
        set { preferences.autoSkip = newValue }
    }

    /// Press Next Episode when the player offers it.
    var autoNext: Bool {
        get { preferences.autoNext }
        set { preferences.autoNext = newValue }
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

    // Audio Output
    var audioDevices: [AudioOutputDevice] { audioCoordinator.devices }
    var currentAudioDevice: AudioOutputDevice? { audioCoordinator.currentDevice }

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
        playbackCoordinator.playInIINA(movie, subtitle: subtitle, screen: playbackScreen)
    }
    func closeIINAPlayback(terminating: Bool = false) { playbackCoordinator.closeIINAPlayback(terminating: terminating) }
    func searchIINASubtitles() -> Bool { playbackCoordinator.searchIINASubtitles() }
    func playMovie(_ movie: Movie, from seconds: Double) { playbackCoordinator.playMovie(movie, from: seconds) }
    func closeMovie() { playbackCoordinator.closeMovie() }
    func retryExternalBrowser() { playbackCoordinator.retryExternalBrowser() }
    func activateExternalBrowser() { playbackCoordinator.activateExternalBrowser() }
    func closeExternalBrowser() { playbackCoordinator.closeExternalBrowser() }

    // MARK: - Private State

    private var controllerInput: ControllerInput?
    private var launchedAppID: String?
    /// A Steam game just launched from Mac TV: watched so Mac TV comes back when it quits.
    var steamWatchUntil: Date?
    var steamGamePID: pid_t?
    /// Mac TV opened Steam or a Steam game, so remote presses may go to it.
    var openedSteam = false
    var steamObservers: [NSObjectProtocol] = []
    var pointer: CGPoint?

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
        let ac = AudioCoordinator()
        self.playbackCoordinator = pc
        self.remoteCoordinator = rc
        self.displayCoordinator = dc
        self.audioCoordinator = ac
        super.init()
        pc.tv = self
        rc.tv = self
        dc.tv = self
        ac.tv = self
        idleCoordinator.tv = self
        // Views watch this controller, so any change a coordinator publishes redraws them.
        coordinatorChanges = [pc.objectWillChange, rc.objectWillChange, dc.objectWillChange, ac.objectWillChange,
                              idleCoordinator.objectWillChange, preferences.objectWillChange].map {
            $0.sink { [weak self] in self?.objectWillChange.send() }
        }
        services = library.services()
    }

    // MARK: - Screensaver and sleep timer

    var screensaver: Bool { idleCoordinator.screensaver }
    var sleepAt: Date? { idleCoordinator.sleepAt }
    @discardableResult
    func noteActivity() -> Bool { idleCoordinator.noteActivity() }
    func showScreensaver() { idleCoordinator.showScreensaver() }
    func screensaverOff() { idleCoordinator.hideScreensaver() }
    func setSleepTimer(minutes: Int) { idleCoordinator.setSleepTimer(minutes: minutes) }

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

    // MARK: - Home screen focus

    func setFocus(_ newFocus: Focus) {
        guard newFocus != focus else { return }
        focus = newFocus
        tilt = .zero
        if case .app(let index) = newFocus, index < columns { shelfAppIndex = index }
    }

    private func handleInLauncher(_ command: RemoteCommand) {
        switch sheets.top {
        case .setup: handleSetup(command); return
        case .profilePicker: handleProfiles(command); return
        case .audioPicker: handleAudioPicker(command); return
        case .playbackCheck:
            switch command { case .back, .select: playbackCheck = nil; default: break }
            return
        case .topShelfPreferences: handleTopShelfPreferences(command); return
        case .addApp: handleAdder(command); return
        case .pairing: handlePairing(command); return
        case .organizer: handleOrganizer(command); return
        case .settings: handleSettings(command); return
        case .controlCenter: handleControlCenter(command); return
        case nil: break
        }
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
        String(describing: (focus, sheets, movies, mode == .launcher))
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
            if playbackCoordinator.iinaOpen {
                playbackCoordinator.activateIINA()
            } else { activateExternalBrowser() }
            return
        case .retryBrowser:
            retryExternalBrowser()
            return
        case .launch(let id):
            if let service = services.first(where: { $0.id == id }) { open(service) }
            return
        case .volume(let delta):
            if playbackCoordinator.iinaOpen { playbackCoordinator.handleIINACommand(command) }
            else { showVolume(SystemControl.changeVolume(by: delta)) }
            return
        case .mute:
            if playbackCoordinator.iinaOpen { playbackCoordinator.handleIINACommand(command) }
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
                sheets.closeDismissible()
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

        if playbackCoordinator.iinaOpen {
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
        sheets.closeDismissible()
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
        sheets.closeDismissible()
        playerFailure = nil
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

    private func pairingChanged() {
        if sheets.pairing {
            remoteCoordinator.pairingGuest = false
            displayCoordinator.resetPairingFocus()
            refreshRemoteURL()
        } else {
            remoteCoordinator.notePairingDismissed()
        }
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

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func showVolume(_ level: VolumeLevel) { notices.showVolume(level) }

    func startControllers() {
        controllerInput = ControllerInput(tv: self)
        controllerInput?.start()
        if ProcessInfo.processInfo.environment["MACTV_PREVIEW_CONTROLLER"] == "1" {
            controllerChanged(ControllerInfo(name: "DualSense Wireless Controller", battery: 0.7, selectSymbol: "xmark.circle",
                                             backSymbol: "circle.circle", menuSymbol: "line.3.horizontal.circle"), connected: true)
        }
    }

    func showControllerNotice(_ notice: ControllerNotice) { notices.showController(notice) }

    func showToast(_ text: String) { notices.showToast(text) }
}
