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
    let preferences: Preferences
    let movieLibrary: MovieLibrary
    let jellyfin: JellyfinServers
    let networkShares: NetworkShares
    let updater: Updater
    let topShelf: TopShelfFeed
    let feedback: Feedback
    private var coordinatorChanges: [AnyCancellable] = []

    // MARK: - State

    @Published private(set) var mode: Mode = .launcher
    @Published private(set) var focus: Focus = .app(0)
    /// Invalidates a pending launch-cancel watchdog so a new start isn't killed by the previous cancel.
    private var launchCancelGeneration = UUID()
    /// Window level before pinning the launch cover above Steam/other apps.
    private var launchCoverRestoredLevel: NSWindow.Level?
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
    /// Tile zoom cover while a web player, Steam game, or Mac app is starting.
    @Published var launchCover: LaunchCoverSession?
    /// Who's watching: their apps and their sign-ins.
    @Published var profile: Profile

    /// The focused button on Mac TV's own Brave screen.
    @Published var browserFocus = 0
    let browserPreferences: BrowserPreferences
    /// Toasts, the volume indicator and controller banners.
    let notices = Notices()
    /// The connected game controller, if any.
    @Published var controller: ControllerInfo?
    /// Last device that issued a command — footer legends show its glyphs.
    @Published var lastInputKind: InputKind = .keyboard

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

    /// Drop any pending cancel watchdog (new launch must not inherit the previous cancel's timer).
    func invalidateLaunchCancelWatchdog() { launchCancelGeneration = UUID() }

    func beginLaunchCover(_ service: Service) {
        invalidateLaunchCancelWatchdog()
        launchCover = LaunchCoverSession(service: service)
    }

    /// Mac app / external browser: same cover + pin + focus hold as Steam (observers via watchForSteamGame).
    func beginExternalLaunchCover(_ service: Service) {
        beginLaunchCover(service)
        scheduleLaunchCoverTimeout()
        pinLaunchCoverAboveApps()
        holdLaunchCoverFocus()
        watchForSteamGame()
        steamWatchUntil = nil
    }

    /// External browser window is placed — drop the cover; protect keeps it front if Steam steals.
    func completeExternalBrowserLaunch(pid: pid_t, bundleID: String) {
        setLaunchedAppID(bundleID)
        steamGamePID = pid
        activateExternalApp(pid: pid)
        markLaunchCoverReady()
        protectExternalAppFocus(pid: pid, generation: launchCancelGeneration)
    }

    func markLaunchCoverReady() {
        guard var cover = launchCover, !cover.ready, !cover.canceling else { return }
        cover.ready = true
        launchCover = cover
    }

    /// Begin the reverse launch animation; returns false if there was nothing to cancel.
    @discardableResult
    func requestLaunchCoverCancel() -> Bool {
        guard var cover = launchCover, !cover.canceling else { return false }
        cover.canceling = true
        cover.ready = false
        launchCover = cover
        return true
    }

    /// Cover exit finished — clear the session (web keeps playing; external apps stay in front).
    func finishLaunchCover() {
        launchCover = nil
        unpinLaunchCover()
    }

    /// Draw the Starting cover above every other app so Steam can't flash through for a frame.
    func pinLaunchCoverAboveApps() {
        guard let window else { return }
        if launchCoverRestoredLevel == nil { launchCoverRestoredLevel = window.level }
        window.level = .screenSaver
        window.orderFrontRegardless()
    }

    /// True while the cover is pinned above other apps (Steam, Mac apps, external browsers).
    var launchCoverPinned: Bool { launchCoverRestoredLevel != nil }

    func unpinLaunchCover() {
        guard let window else {
            launchCoverRestoredLevel = nil
            return
        }
        if let level = launchCoverRestoredLevel {
            window.level = level
            launchCoverRestoredLevel = nil
        }
    }

    /// Launch cover finished reversing — tear down immediately (no half-state that can stick).
    func completeLaunchCoverCancel() { finishGoingHome() }
    var currentLocalMovie: Movie? { playbackCoordinator.currentLocalMovie }
    var localMoviePlayer: String { playbackCoordinator.localMoviePlayer }
    var iinaPlaybackError: String? { playbackCoordinator.iinaPlaybackError }
    var iinaPlaybackStatus: String { playbackCoordinator.iinaPlaybackStatus }
    var externalBrowser: BrowserSession? { playbackCoordinator.externalBrowser }
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
    /// Arrange Apps hold-to-remove; timer/progress live here so `AppOrganizer` stays a plain value.
    var removeHoldTimer: Timer?
    var removeHoldID: String?
    @Published var removeHoldProgress: CGFloat = 0
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

    init(library: AppLibrary, profiles: ProfileStore? = nil, browserPreferences: BrowserPreferences? = nil,
         services appServices: AppServices = AppServices()) {
        preferences = appServices.preferences
        movieLibrary = appServices.movieLibrary
        jellyfin = appServices.jellyfin
        networkShares = appServices.networkShares
        updater = appServices.updater
        topShelf = appServices.topShelf
        feedback = appServices.feedback
        self.browserPreferences = browserPreferences ?? BrowserPreferences()
        let store = profiles ?? ProfileStore(folder: library.storageFolder)
        self.profiles = store
        self.profile = store.current
        self.library = library
        let pc = PlaybackCoordinator(jellyfin: appServices.jellyfin)
        let rc = RemoteCoordinator()
        let dc = DisplayCoordinator(preferences: appServices.preferences)
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
        if let index = services.firstIndex(where: { $0.id == shelfID }),
           homeLayout == .pages || index < columns {
            shelfAppIndex = index
        } else { shelfAppIndex = 0 }
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
        if case .app(let index) = newFocus, homeLayout == .pages || index < columns {
            shelfAppIndex = index
        }
    }

    func stepHomeLayout(forward: Bool = true) {
        let all = HomeLayout.allCases
        let index = all.firstIndex(of: homeLayout) ?? 0
        homeLayout = all[(index + (forward ? 1 : all.count - 1)) % all.count]
    }

    private func handleInLauncher(_ command: RemoteCommand) {
        // External launch cover (Steam / Mac): Back cancels like Home; ignore other input.
        if launchCover != nil {
            if case .back = command { goHome() }
            return
        }
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
        case .select, .selectDown:
            switch focus {
            case .app(let index): if services.indices.contains(index) { open(services[index]) }
            case .shelf(let index): activateShelf(index)
            case .status(let item): activateStatus(item)
            }
        case .selectUp:
            break
        case .back:
            switch focus {
            case .status: setFocus(shelfCount > 0 ? .shelf(0) : .app(shelfAppIndex))
            case .shelf: setFocus(.app(shelfAppIndex))
            case .app(let index):
                if homeLayout == .pages, index >= columns {
                    setFocus(.app(index % columns))
                } else if inGrid {
                    setFocus(.app(0))
                }
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
        // Only on a change: this redraws every screen watching the controller.
        if InputKind(source) != lastInputKind { lastInputKind = InputKind(source) }
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

        // Select down/up only matter for Arrange hold-to-remove; elsewhere down is a normal Select.
        var command = command
        let arrangeHold = mode == .launcher && sheets.top == .organizer
        if case .selectDown = command, !arrangeHold { command = .select }
        if case .selectUp = command, !arrangeHold { return }

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
            // Browser launch cover: Back cancels; don't forward into the waking browser yet.
            if let cover = launchCover, !cover.canceling {
                if case .back = command { goHome() }
                return
            }
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
            // During Steam/Mac cover, don't forward into Steam — reclaim Mac TV (same as before simplify).
            if launchCover != nil, launchCover?.canceling != true {
                bringToFront()
                if case .back = command { goHome() }
                return
            }
            forwardToFrontApp(command)
            return
        }

        if source == .remote || source == .controller, !NSApp.isActive {
            bringToFront()
        }

        switch mode {
        case .launcher:
            let before = feedbackState
            let holdAlready = isHoldingRemove
            handleInLauncher(command)
            let changed = feedbackState != before
            switch command {
            case .move where changed: feedback.play(.move, from: source)
            case .select: feedback.play(.select, from: source)
            // One click on first Down; repeats / continued hold stay quiet.
            case .selectDown where !holdAlready: feedback.play(.select, from: source)
            case .back where changed: feedback.play(.back, from: source)
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
        if case .web = service.kind {
            // A fixed word for other browsers: bundle ids aren't sent.
            let choice = browserPreferences.choice(for: profile.id)
            if case .app = choice { opened["player"] = "other" } else { opened["player"] = choice.rawValue }
        }
        Analytics.send(.appOpened, opened)
        playbackCoordinator.resetPlaybackRequest()
        sheets.closeDismissible()
        switch service.kind {
        case .web(let url):
            playbackCoordinator.playWeb(service, url: url)
        case .app(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            beginExternalLaunchCover(service)
            launchedAppID = bundleID
            let generation = launchCancelGeneration
            // Launch in the background — Mac TV keeps the cover until fullscreen hand-off.
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
                Task { @MainActor in
                    guard let self, self.launchCancelGeneration == generation,
                          self.launchCover != nil, self.launchCover?.canceling != true else { return }
                    if let error {
                        self.showToast(error.localizedDescription)
                        self.finishGoingHome()
                        return
                    }
                    guard let app else {
                        self.finishGoingHome()
                        return
                    }
                    // A Mac app opens its own way (no forced full screen): hand off as soon as it's running.
                    self.steamGamePID = app.processIdentifier
                    app.unhide()
                    self.activateExternalApp(pid: app.processIdentifier)
                    self.markLaunchCoverReady()
                }
            }
        case .steam(let appID):
            beginLaunchCover(service)
            openedSteam = true
            pinLaunchCoverAboveApps()
            holdLaunchCoverFocus()
            // Hide Steam before the URL wakes it — covers the one-frame flash.
            if appID != SteamLibrary.bigPicture.appID {
                suppressSteamUIWhileLaunchingGame()
            }
            // Don't let Steam jump in front of the Starting cover; hand-off is Mac TV's call.
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.open(SteamLibrary.launchURL(for: appID), configuration: config)
            if appID == SteamLibrary.bigPicture.appID {
                watchForSteamBigPicture()
            } else {
                watchForSteamGame()
            }
            scheduleLaunchCoverTimeout()
        case .movies:
            openMovies()
        case .addApp:
            adder = AppAdder()
        case .settings:
            openSettings()
        }
    }

    /// After the process is up: wait for fullscreen, then mark the cover ready.
    func handOffExternalLaunch(pid: pid_t, generation: UUID? = nil) {
        let generation = generation ?? launchCancelGeneration
        GameWindow.fillTV(pid: pid, screen: window?.screen) { [weak self] _ in
            guard let self, self.launchCancelGeneration == generation,
                  self.launchCover != nil, self.launchCover?.canceling != true else { return }
            // Hand-off is Mac TV's call: hide Steam, game front, then drop the cover.
            self.suppressSteamUIWhileLaunchingGame()
            self.activateExternalApp(pid: pid)
            self.markLaunchCoverReady()
            self.protectExternalAppFocus(pid: pid, generation: generation)
        }
    }

    /// Put the launched game/app in front (Steam must not win this race).
    func activateExternalApp(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        app.activate(options: [.activateIgnoringOtherApps])
        _ = AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue)
    }

    /// Steam often reactivates right after a game goes fullscreen — keep the game in front for a bit.
    func protectExternalAppFocus(pid: pid_t, generation: UUID) {
        Task { @MainActor [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.launchCancelGeneration == generation, self.steamGamePID == pid else { return }
                let front = NSWorkspace.shared.frontmostApplication
                if front?.processIdentifier == pid { continue }
                // Only fight Steam / Mac TV — leave other apps alone if the user switched away.
                let stolenBySteam = front?.bundleIdentifier.map {
                    $0 == SteamLibrary.bundleID || $0.hasPrefix("com.valvesoftware.")
                } ?? false
                let stolenByUs = front?.bundleIdentifier == Bundle.main.bundleIdentifier
                guard stolenBySteam || stolenByUs else { return }
                if stolenBySteam { self.suppressSteamUIWhileLaunchingGame() }
                self.activateExternalApp(pid: pid)
            }
        }
    }

    /// Cover stuck waiting for a game/app: dismiss it so Home isn't locked behind Starting…, and show
    /// Steam, which is probably waiting on the user.
    private func scheduleLaunchCoverTimeout() {
        let generation = launchCancelGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, self.launchCancelGeneration == generation,
                  let cover = self.launchCover, !cover.ready, !cover.canceling else { return }
            self.markLaunchCoverReady()
            self.steamWatchUntil = nil
            if case .steam = cover.service.kind {
                self.showToast("\(cover.service.name) is still starting. Steam may need you.")
                self.revealSteamAfterStuckLaunch()
            } else {
                self.showToast("\(cover.service.name) is taking a while.")
            }
        }
    }

    /// A website that never finishes loading (some keep fetching) still appears after a while.
    func scheduleWebLaunchReveal() {
        let generation = launchCancelGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.launchCancelGeneration == generation else { return }
            self.markLaunchCoverReady()
        }
    }

    /// While the cover is up, reclaim focus if Steam/Mac still activates (AX if needed).
    func holdLaunchCoverFocus() {
        bringToFront()
        let generation = launchCancelGeneration
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, self.launchCancelGeneration == generation,
                      let cover = self.launchCover, !cover.ready, !cover.canceling else { return }
                if case .steam = cover.service.kind {
                    self.suppressSteamUIWhileLaunchingGame()
                }
                if NSApp.isActive { continue }
                self.claimFrontForLaunchCover()
            }
        }
    }

    /// Stronger than `bringToFront` alone — Steam often wins a plain activate race.
    func claimFrontForLaunchCover() {
        bringToFront()
        window?.orderFrontRegardless()
        _ = AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(getpid()),
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue)
    }

    func goHome() {
        // First Home during launch: play reverse animation. Second Home (or stuck cancel): force tear-down.
        if let cover = launchCover, !cover.canceling {
            let generation = UUID()
            launchCancelGeneration = generation
            _ = requestLaunchCoverCancel()
            // Stop waiting for Steam/Mac without killing the app that may still be starting.
            steamWatchUntil = nil
            if case .player = mode {
                playbackCoordinator.resetPlaybackRequest()
                playbackCoordinator.webView?.stopLoading()
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1200))
                guard let self, self.launchCancelGeneration == generation else { return }
                if self.launchCover != nil {
                    self.finishGoingHome()
                }
            }
            return
        }
        finishGoingHome()
    }

    private func finishGoingHome() {
        launchCancelGeneration = UUID()
        launchCover = nil
        unpinLaunchCover()
        // Leaving a browser window lands on the desktop Space, so coming back needs more than activating.
        let leavingBrowser = playbackCoordinator.externalBrowser != nil
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
        openedSteam = false
        steamWatchUntil = nil
        steamGamePID = nil
        displayCoordinator.releasePlaybackKeepAwake()
        if leavingBrowser { takeFocusBack() } else { bringToFront() }
    }

    var idleForUpdate: Bool {
        (screensaver || displaysSleeping) && mode == .launcher && setup == nil && !playbackCoordinator.isAnyPlaybackActive
    }

    var braveInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrowserChoice.braveBundleID) != nil }

    /// The browsers installed on this Mac. Tests replace it so they don't depend on what the machine has.
    var browserLookup: () -> [InstalledBrowser] = BrowserDiscovery.installed { didSet { browserCache = nil } }
    private var browserCache: (browsers: [InstalledBrowser], at: Date)?

    /// Built-in, then Brave if it's installed, then the other browsers on this Mac.
    var websitePlayers: [(choice: BrowserChoice, name: String)] {
        if browserCache == nil || browserCache!.at.timeIntervalSinceNow < -10 {
            browserCache = (browserLookup(), Date())
        }
        let browsers = browserCache!.browsers
        var players: [(choice: BrowserChoice, name: String)] = [(.embedded, "Built-in")]
        if browsers.contains(where: { $0.bundleID == BrowserChoice.braveBundleID }) { players.append((.brave, "Brave")) }
        players += browsers.filter { $0.bundleID != BrowserChoice.braveBundleID }.map { (.app($0.bundleID), $0.name) }
        return players
    }

    var websitePlayerName: String {
        let choice = browserPreferences.choice(for: profile.id)
        if let player = websitePlayers.first(where: { $0.choice == choice }) { return player.name }
        // A browser that has since been removed: websites play in Mac TV.
        return choice == .brave ? "Brave" : "Built-in"
    }

    @discardableResult
    func setWebsitePlayer(_ raw: String) -> Bool {
        guard let choice = BrowserChoice(rawValue: raw), websitePlayers.contains(where: { $0.choice == choice }) else {
            return false
        }
        browserPreferences.setChoice(choice, for: profile.id)
        objectWillChange.send()
        return true
    }

    func stepWebsitePlayer(forward: Bool = true) {
        let players = websitePlayers
        guard players.count > 1 else {
            showToast("Install a browser such as Brave to choose it.")
            return
        }
        let current = players.firstIndex { $0.choice == browserPreferences.choice(for: profile.id) } ?? 0
        let next = (current + (forward ? 1 : players.count - 1)) % players.count
        setWebsitePlayer(players[next].choice.rawValue)
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

    /// Comes back in front after another app's window closed, onto the Space Mac TV's full-screen window is in.
    /// Opening Mac TV through Launch Services activates it the way a Dock click does, Space switch included;
    /// if macOS still leaves it in the background, it marks itself frontmost through Accessibility.
    func takeFocusBack() {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            if let error { Log.app.failure("Reopening Mac TV", error) }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            if !NSApp.isActive {
                _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()),
                                                 kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
            // Ordering the window front once Mac TV is active moves to the Space it's in.
            if self.window?.isOnActiveSpace == false { self.bringToFront() }
            try? await Task.sleep(for: .milliseconds(700))
            Log.app.notice("Taking focus back: active \(NSApp.isActive, privacy: .public), window on this Space \(self.window?.isOnActiveSpace ?? false, privacy: .public)")
        }
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
