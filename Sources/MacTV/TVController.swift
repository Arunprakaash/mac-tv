import AppKit
import Combine
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
    case screenOff, sleepMac
    case sleepTimer(minutes: Int)
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
        case "sleep": self = .sleepMac
        case "sleeptimer": self = .sleepTimer(minutes: json["m"] as? Int ?? 0)
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
    }

    /// What has focus on the home screen: an app tile, or an item in the Top Shelf.
    enum Focus: Equatable {
        case app(Int)
        case shelf(Int)
    }

    @Published private(set) var mode: Mode = .launcher
    @Published private(set) var focus: Focus = .app(0)
    /// The top-row app whose content the Top Shelf shows.
    @Published private(set) var shelfAppIndex = 0
    /// Pointer position over the focused tile, -0.5…0.5 on each axis, for the parallax tilt.
    @Published var tilt: CGSize = .zero
    @Published var pairing = false
    /// The add-app sheet on the TV, while it's open.
    @Published var adder: AppAdder?
    /// Shown after a few idle minutes on the home screen; any input dismisses it.
    @Published private(set) var screensaver = false
    @Published private(set) var sleepAt: Date?
    @Published private(set) var webView: WKWebView?
    @Published private(set) var toast: String?
    /// Addresses a phone can open the remote at, one per network this Mac is on.
    @Published private(set) var remoteLinks: [RemoteLink] = []

    /// The home screen's apps, in order; changes when the user adds or removes apps.
    @Published private(set) var services: [Service] = []
    let library = AppLibrary()
    let columns = 6
    let history = WatchHistory()
    let deviceName = Host.current().localizedName ?? "Mac"
    weak var window: NSWindow?
    var remoteToken = ""
    var remotePort: UInt16 = 0 {
        didSet {
            refreshRemoteURL()
            // Wi-Fi changes and Tailscale starting or stopping don't announce themselves; poll.
            addressTimer?.invalidate()
            addressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRemoteURL() }
            }
        }
    }

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

    /// Stop the Mac sleeping by itself while Mac TV is open, so the phone remote always reaches it.
    /// The screen can still turn off.
    var keepMacAwake: Bool {
        get { UserDefaults.standard.bool(forKey: "keepMacAwake") }
        set { UserDefaults.standard.set(newValue, forKey: "keepMacAwake"); applyPower() }
    }

    /// Keep running with the lid closed even on battery or without the TV connected.
    var lidOverride: Bool {
        get { UserDefaults.standard.bool(forKey: "lidOverride") }
        set { UserDefaults.standard.set(newValue, forKey: "lidOverride"); applyPower() }
    }

    /// Lid, power and displays, refreshed every few seconds while Mac TV runs.
    @Published private(set) var power = PowerStatus()
    /// Whether the lid override is in effect right now.
    @Published private(set) var lidSleepOff = false

    var phonePaired: Bool {
        get { UserDefaults.standard.bool(forKey: "phonePaired") }
        set { UserDefaults.standard.set(newValue, forKey: "phonePaired") }
    }

    private var addressTimer: Timer?
    private var captureTimer: Timer?
    private let keepAwake = KeepAwake()
    private var toastTask: Task<Void, Never>?
    private var launchedAppID: String?
    private var pointer: CGPoint?
    private var popups: [NSWindow] = []
    private var historyObserver: AnyCancellable?
    private var sleepTimer: Timer?
    private var idleTimer: Timer?
    private let macAwake = KeepAwake(kIOPMAssertionTypePreventUserIdleSystemSleep)
    private var powerTimer: Timer?
    private var lidGuard: Process?
    private var wakeObserver: NSObjectProtocol?
    private static let lowBattery = 20
    private var lastActivity = Date()
    private static let screensaverDelay: TimeInterval = 5 * 60

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: ["autoSkip": true, "autoNext": true, "keepMacAwake": true])
        services = library.services()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        historyObserver = history.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    // MARK: Screensaver and sleep timer

    /// Any keyboard, mouse or remote input. Returns true when it only woke the screensaver.
    @discardableResult
    func noteActivity() -> Bool {
        lastActivity = Date()
        guard screensaver else { return false }
        screensaver = false
        return true
    }

    private func checkIdle() {
        if mode == .launcher, !pairing, !screensaver, Date().timeIntervalSince(lastActivity) > Self.screensaverDelay {
            screensaver = true
        }
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
                SystemControl.displayOff()
            }
        }
        showToast("Sleep timer: \(minutes) minutes")
    }

    // MARK: Power and the lid

    func startPowerManagement() {
        applyPower()
        // Often enough to win back the lid switch soon after powerd rewrites it.
        powerTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPower() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPower() }
        }
    }

    func stopPowerManagement() {
        powerTimer?.invalidate()
        macAwake.release()
        if lidSleepOff { releaseLid() }
    }

    func refreshPower() {
        power = PowerStatus.current()
        guard lidSleepOff else { return }
        if let reason = lidOverrideStopReason() {
            lidOverride = false
            showToast(reason)
        } else {
            LidSleep.setPrevented(true)
        }
    }

    private func applyPower() {
        power = PowerStatus.current()
        keepMacAwake ? macAwake.hold(reason: "Mac TV is open, so the phone remote can reach it") : macAwake.release()

        if lidOverride, lidSleepOff == false {
            if let reason = lidOverrideStopReason() {
                UserDefaults.standard.set(false, forKey: "lidOverride")
                showToast(reason)
            } else if LidSleep.setPrevented(true) {
                lidSleepOff = true
                lidGuard = LidSleep.startGuard()
            } else {
                UserDefaults.standard.set(false, forKey: "lidOverride")
                showToast("This Mac doesn't allow staying awake with the lid closed")
            }
        } else if !lidOverride, lidSleepOff {
            releaseLid()
        }
    }

    private func releaseLid() {
        LidSleep.restore()
        lidGuard?.terminate()
        lidGuard = nil
        lidSleepOff = false
    }

    /// Why the lid override has to stop now, if it does: a closed Mac that never sleeps can run
    /// its battery flat or overheat in a bag.
    private func lidOverrideStopReason() -> String? {
        if !power.onAC, let battery = power.battery, battery < Self.lowBattery {
            return "Battery low: closing the lid sleeps the Mac again"
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return "Mac is hot: closing the lid sleeps the Mac again"
        default: return nil
        }
    }

    /// One line for the remote about what closing the lid will do.
    var lidStatus: String {
        if lidSleepOff {
            return power.onAC ? "Lid sleep is off while Mac TV is open. Keep the Mac somewhere ventilated."
                : "Lid sleep is off while Mac TV is open, on battery. It turns back on below \(Self.lowBattery)%."
        }
        if power.closedLidModeReady { return "You can close the lid: the TV and power are connected." }
        if !power.onAC { return "Closing the lid will sleep the Mac. Connect power, or turn on the option below." }
        return "Closing the lid will sleep the Mac. Connect the TV, or turn on the option below."
    }

    // MARK: Adding and removing apps

    private func reloadServices() {
        services = library.services()
        if case .app(let index) = focus, index >= services.count { setFocus(.app(max(services.count - 1, 0))) }
        if shelfAppIndex >= min(columns, services.count) { shelfAppIndex = 0 }
        if case .shelf = focus, shelfCount == 0 { setFocus(.app(shelfAppIndex)) }
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
        Task { [weak self] in
            let png = await IconFinder.icon(forSite: url, name: app.name)
            await MainActor.run { self?.useIcon(png, for: app.id) }
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

    private func useIcon(_ png: Data?, for id: String) {
        if let png, let image = NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            library.setIcon(png, accent: TileArt.brandColor(from: image), for: id)
        }
        Icons.forget(id)
        reloadServices()
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

    /// The phone remote's app-management requests.
    func handleAppsRequest(_ request: HTTPRequest) -> HTTPResponse? {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        switch (request.method, request.path) {
        case ("GET", "/macapps"):
            let installed = Set(services.compactMap { service -> String? in
                if case .app(let bundleID) = service.kind { return bundleID }
                return nil
            })
            return .json(InstalledApps.matching(request.query["q"] ?? "").map {
                ["name": $0.name, "bundleID": $0.bundleID, "added": installed.contains($0.bundleID)]
            })
        case ("POST", "/apps/add"):
            let app: AddedApp?
            if let bundleID = body["bundleID"] as? String {
                app = addMacApp(bundleID: bundleID)
            } else if let address = body["url"] as? String {
                app = addWebsite(name: body["name"] as? String, address: address)
            } else {
                app = nil
            }
            guard let app else { return .json(["error": "Couldn't add that. Check the address."], status: "400 Bad Request") }
            return .json(["ok": true, "id": app.id, "name": app.name])
        case ("POST", "/apps/remove"):
            guard let id = body["id"] as? String else { return .json(["error": "Missing app"], status: "400 Bad Request") }
            removeApp(id)
            return .json(["ok": true])
        case ("POST", "/apps/restore"):
            restoreBuiltInApps()
            return .json(["ok": true])
        default:
            return nil
        }
    }

    // MARK: Home screen

    var shelfService: Service { services.indices.contains(shelfAppIndex) ? services[shelfAppIndex] : services[0] }
    var shelfItems: [WatchItem] { Array(history.items(for: shelfService.id).prefix(6)) }

    /// True when focus is below the top row; the Top Shelf scrolls away.
    var inGrid: Bool {
        if case .app(let index) = focus { return index >= columns }
        return false
    }

    /// How many things in the Top Shelf can take focus.
    var shelfCount: Int {
        guard shelfService.isWeb else { return 0 }
        switch shelfService.shelf {
        case .showcase: return shelfItems.isEmpty ? 1 : 2
        case .row: return max(shelfItems.count, 1)
        }
    }

    func setFocus(_ newFocus: Focus) {
        guard newFocus != focus else { return }
        focus = newFocus
        tilt = .zero
        if case .app(let index) = newFocus, index < columns { shelfAppIndex = index }
    }

    /// The pointer over a tile focuses it, but only within the row group already in view: moving
    /// between the dock and the grid slides the whole screen, which would put a different tile
    /// under a resting pointer and bounce focus back and forth. Clicks, keys, the remote and
    /// scrolling change rows instead.
    func hover(_ index: Int, tilt: CGSize) {
        if case .shelf = focus { return }
        guard (index >= columns) == inGrid else { return }
        setFocus(.app(index))
        self.tilt = tilt
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
                }
            }
        case .shelf(let index):
            switch direction {
            case .left: if index > 0 { setFocus(.shelf(index - 1)) }
            case .right: if index + 1 < shelfCount { setFocus(.shelf(index + 1)) }
            case .down: setFocus(.app(shelfAppIndex))
            case .up: break
            }
        }
    }

    func activateShelf(_ index: Int) {
        let service = shelfService, items = shelfItems
        switch service.shelf {
        case .showcase:
            if index == 0, let item = items.first { resume(item) } else { open(service) }
        case .row:
            if items.indices.contains(index) { resume(items[index]) } else { open(service) }
        }
    }

    private func handleInLauncher(_ command: RemoteCommand) {
        if adder != nil {
            handleAdder(command)
            return
        }
        if pairing {
            switch command {
            case .select, .back: pairing = false
            default: break
            }
            return
        }
        switch command {
        case .move(let direction): moveFocus(direction)
        case .select:
            switch focus {
            case .app(let index): if services.indices.contains(index) { open(services[index]) }
            case .shelf(let index): activateShelf(index)
            }
        case .back:
            if case .shelf = focus { setFocus(.app(shelfAppIndex)) } else if inGrid { setFocus(.app(0)) }
        case .pointer(let dx, let dy): movePointer(dx: dx, dy: dy)
        case .click: clickPointer()
        default: break
        }
    }

    // MARK: Remote

    func refreshRemoteURL() {
        guard remotePort != 0 else { return }
        let found: [(label: String, ip: String?)] = [("Same Wi-Fi", LAN.ipv4()), ("Tailscale", LAN.tailscaleIPv4())]
        let addresses = found.compactMap { entry in entry.ip.map { (entry.label, "http://\($0):\(remotePort)") } }
        guard addresses.map(\.1) != remoteLinks.map(\.address) else { return }
        remoteLinks = addresses.map { label, address in
            RemoteLink(label: label, address: address, qr: QRCode.image(for: "\(address)/?k=\(remoteToken)"))
        }
    }

    /// What the phone remote shows. Only called for a phone that knows the pairing code.
    func remoteState() -> [String: Any] {
        phonePaired = true
        var state: [String: Any] = [
            "device": deviceName,
            "mode": "launcher",
            "apps": services.filter { $0.kind != .settings && $0.kind != .addApp }.map {
                ["id": $0.id, "name": $0.name, "icon": Icons.image(for: $0) != nil]
            },
            "canRestore": library.hasHiddenBuiltIns,
            // Which sheet is open on the TV, if any: the remote can show it.
            "sheet": adder != nil ? "add-app" : (pairing ? "pairing" : ""),
            "autoSkip": autoSkip,
            "autoNext": autoNext,
            "keepMacAwake": keepMacAwake,
            "lidOverride": lidOverride,
            "lidStatus": lidStatus,
            // Minutes left on the sleep timer; 0 when it's off.
            "sleepMinutes": sleepAt.map { max(1, Int(($0.timeIntervalSinceNow / 60).rounded(.up))) } ?? 0,
        ]
        if case .player(let service) = mode {
            state["mode"] = "player"
            state["current"] = ["id": service.id, "name": service.name,
                                "title": history.items(for: service.id).first?.title ?? ""]
        }
        return state
    }

    func iconPNG(for id: String) -> Data? {
        services.first { $0.id == id }.flatMap { Icons.png(for: $0) }
    }

    func handle(_ command: RemoteCommand) {
        // The first press only wakes the screensaver.
        if noteActivity() { return }

        switch command {
        case .pointer, .click, .scroll: break
        default: NSCursor.setHiddenUntilMouseMoves(true)
        }

        // Commands that mean the same thing everywhere.
        switch command {
        case .home: goHome(); return
        case .launch(let id):
            if let service = services.first(where: { $0.id == id }) { open(service) }
            return
        case .volume(let delta): SystemControl.changeVolume(by: delta); return
        case .mute: SystemControl.toggleMute(); return
        case .screenOff: SystemControl.displayOff(); return
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
        default: break
        }

        // A Mac app Mac TV opened is in front: forward the basics to it.
        if let launchedAppID, !NSApp.isActive,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == launchedAppID {
            forwardToFrontApp(command)
            return
        }

        switch mode {
        case .launcher: handleInLauncher(command)
        case .player(let service): handleInPlayer(command, service: service)
        }
    }

    // MARK: Opening things

    func open(_ service: Service) {
        switch service.kind {
        case .web(let url):
            play(service, url: url)
        case .app(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            launchedAppID = bundleID
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .addApp:
            adder = AppAdder()
        case .settings:
            pairing = true
        }
    }

    func resume(_ item: WatchItem) {
        guard let service = services.first(where: { $0.id == item.serviceID }) else { return }
        play(service, url: item.url)
    }

    private func play(_ service: Service, url: URL) {
        let web = makeWebView(for: service)
        web.load(URLRequest(url: url))
        webView = web
        mode = .player(service)
        pointer = nil
        keepAwake.hold(reason: "Watching \(service.name) in Mac TV")
        startCapturing(service)
        bringToFront()
        Task { @MainActor [weak self] in self?.window?.makeFirstResponder(web) }
        showToast("Home on your phone remote, or ⌘⇧H, comes back here")
    }

    func goHome() {
        if let web = webView {
            captureNow(from: web)
            // Releasing the page stops playback; pause first so audio cuts immediately.
            web.pauseAllMediaPlayback(completionHandler: nil)
            web.stopLoading()
        }
        captureTimer?.invalidate()
        popups.forEach { $0.close() }
        popups.removeAll()
        webView = nil
        mode = .launcher
        pairing = false
        pointer = nil
        launchedAppID = nil
        keepAwake.release()
        bringToFront()
    }

    // MARK: Watch history

    private func startCapturing(_ service: Service) {
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let web = self.webView else { return }
                self.captureNow(from: web)
            }
        }
    }

    /// Notes what's playing so the Top Shelf can offer to resume it.
    private func captureNow(from web: WKWebView) {
        guard case .player(let service) = mode else { return }
        web.evaluateJavaScript(WatchHistory.captureScript) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let json = result as? String, let data = json.data(using: .utf8),
                      let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let url = (info["url"] as? String).flatMap(URL.init(string:))
                else { return }
                var title = (info["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if title?.isEmpty == true || title == service.name { title = nil }
                self.history.record(WatchItem(
                    serviceID: service.id, url: url, title: title,
                    image: (info["image"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                    progress: info["progress"] as? Double, date: Date()))
            }
        }
    }

    // MARK: Player

    private func handleInPlayer(_ command: RemoteCommand, service: Service) {
        guard let web = webView else { return }
        switch command {
        case .move(let direction): sendKey(.direction(direction), to: web)
        case .select: sendKey(.enter, to: web)
        case .back:
            if !service.dpadNavigation {
                // TV-style web apps (youtube.com/tv) treat Escape as their own back button.
                sendKey(.escape, to: web)
            } else if web.canGoBack {
                web.goBack()
            } else {
                goHome()
            }
        case .playPause:
            web.evaluateJavaScript(Self.togglePlaybackJS) { [weak self] result, _ in
                MainActor.assumeIsolated {
                    if (result as? String) == "none" { self?.sendKey(.space, to: web) }
                }
            }
        case .seek(let forward):
            // Players map arrows to seek; Netflix rejects direct currentTime changes.
            sendKey(forward ? .right : .left, to: web)
        case .text(let text):
            for character in text {
                sendKey(character == "\n" ? .enter : Key(code: 0, chars: String(character)), to: web)
            }
        case .deleteBackward: sendKey(.delete, to: web)
        case .pointer(let dx, let dy): movePointer(dx: dx, dy: dy)
        case .click: clickPointer()
        case .scroll(let dy): scrollPage(web, by: dy)
        case .openInBrowser:
            if let url = web.url {
                goHome()
                NSWorkspace.shared.open(url)
            }
        default: break
        }
    }

    private static let togglePlaybackJS = """
        (() => {
          const videos = [...document.querySelectorAll('video')];
          const v = videos.find(v => !v.paused) || videos.find(v => v.readyState > 0);
          if (!v) return 'none';
          if (v.paused) { v.play(); return 'playing'; }
          v.pause(); return 'paused';
        })()
        """

    private func sendKey(_ key: Key, to web: WKWebView) {
        guard let window else { return }
        if window.firstResponder !== web { window.makeFirstResponder(web) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: key.flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: key.chars, charactersIgnoringModifiers: key.chars,
                isARepeat: false, keyCode: key.code)
            else { continue }
            window.sendEvent(event)
        }
    }

    // MARK: Touchpad

    private func movePointer(dx: Double, dy: Double) {
        guard let window, let bounds = window.contentView?.bounds else { return }
        var point = pointer ?? CGPoint(x: bounds.midX, y: bounds.midY)
        point.x = min(max(point.x + dx, 0), bounds.width - 1)
        point.y = min(max(point.y - dy, 0), bounds.height - 1) // window y grows upward
        pointer = point

        // Show the real cursor where the virtual pointer is.
        let onScreen = window.convertPoint(toScreen: point)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.x, y: primaryHeight - onScreen.y))
        NSCursor.setHiddenUntilMouseMoves(false)
        postMouse(.mouseMoved, at: point)
    }

    private func clickPointer() {
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

    private func scrollPage(_ web: WKWebView, by dy: Double) {
        let point = pointer ?? CGPoint(x: web.bounds.midX, y: web.bounds.midY)
        let x = Int(point.x), y = Int(web.bounds.height - point.y), amount = Int(dy)
        web.evaluateJavaScript("""
            ((x, y, dy) => {
              for (let el = document.elementFromPoint(x, y); el && el !== document.body; el = el.parentElement) {
                const style = getComputedStyle(el);
                if (/(auto|scroll)/.test(style.overflowY) && el.scrollHeight > el.clientHeight) { el.scrollBy(0, dy); return; }
              }
              window.scrollBy(0, dy);
            })(\(x), \(y), \(amount))
            """)
    }

    // MARK: Mac apps

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
        default: return
        }
        SystemControl.postKeyToFrontApp(code)
    }

    // MARK: Helpers

    private func makeWebView(for service: Service) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // keeps sign-ins between launches
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController.addUserScript(
            WKUserScript(source: AutoPlay.script(skip: autoSkip, next: autoNext), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        if service.dpadNavigation {
            config.userContentController.addUserScript(
                WKUserScript(source: SpatialNav.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = service.userAgent
        web.uiDelegate = self
        web.navigationDelegate = self
        web.underPageBackgroundColor = .black
        web.isInspectable = true
        return web
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.toast = nil }
        }
    }
}

// Sign-in pages (Google, Apple, Amazon) open popups that talk back to their opener.
extension TVController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 700), configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self
        let popupWindow = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                                   backing: .buffered, defer: false)
        popupWindow.contentView = popup
        popupWindow.isReleasedWhenClosed = false
        popupWindow.level = .floating
        if let frame = window?.frame {
            popupWindow.setFrameOrigin(NSPoint(x: frame.midX - 260, y: frame.midY - 350))
        }
        popupWindow.makeKeyAndOrderFront(nil)
        popups.append(popupWindow)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let popupWindow = popups.first(where: { $0.contentView === webView }) else { return }
        popupWindow.close()
        popups.removeAll { $0 === popupWindow }
    }
}

// Google sign-in (YouTube, YouTube Music) refuses embedded browsers; switch identity on its pages.
extension TVController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame ?? true, let host = navigationAction.request.url?.host() else { return .allow }
        let signingIn = host == "accounts.google.com" || host.hasSuffix(".accounts.google.com")
        var usual = UserAgent.safari
        if case .player(let service) = mode { usual = service.userAgent }
        let wanted = signingIn ? UserAgent.googleSignIn : usual
        if webView.customUserAgent != wanted { webView.customUserAgent = wanted }
        return .allow
    }
}
