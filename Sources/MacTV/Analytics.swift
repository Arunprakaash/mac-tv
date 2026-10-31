import AppKit
import TelemetryDeck

/// Opt-in, anonymous usage analytics through TelemetryDeck, so Mac TV can be improved from how it's
/// really used. Off until the user says yes (in setup, once after an update, or in Settings › About).
///
/// What's sent: which features are used (Control Center, Settings sections, the screen saver's
/// wallpaper type, how Mac TV is controlled), which built-in apps are opened, setup progress, and the
/// SDK's basics (Mac TV and macOS versions, Mac model, language). The user is a random ID kept only in
/// Mac TV's own settings, hashed before it leaves the Mac.
///
/// Never sent: what anyone watches, titles, web addresses, added websites or apps by name, file or
/// folder names, profile names. Every event is defined in `Event` below, and nowhere else.
@MainActor
enum Analytics {
    enum Consent: String {
        case unasked, granted, declined
    }

    enum Event: String {
        case launched = "Launched"
        case setupFinished = "Setup.finished"
        case appOpened = "App.opened"
        case controlCenterOpened = "ControlCenter.opened"
        case controlUsed = "ControlCenter.used"
        case settingsOpened = "Settings.opened"
        case inputUsed = "Input.used"
        case moviePlayed = "Movie.played"
        case screenSaverStarted = "ScreenSaver.started"
        case profileAdded = "Profile.added"
    }

    /// Mac TV's TelemetryDeck App ID, from Info.plist. Without one, analytics is off and never offered.
    static let appID: String = (Bundle.main.object(forInfoDictionaryKey: "TelemetryDeckAppID") as? String ?? "")
        .trimmingCharacters(in: .whitespaces)

    static var available: Bool { !appID.isEmpty }

    static var consent: Consent {
        get { UserDefaults.standard.string(forKey: "analyticsConsent").flatMap(Consent.init(rawValue:)) ?? .unasked }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "analyticsConsent") }
    }

    static var enabled: Bool { available && consent == .granted }

    /// The SDK's configuration object, kept so sending can be switched off again without a relaunch.
    private static var config: TelemetryDeck.Config?
    private static var started: Bool { config != nil }
    private static var inputsSeen: Set<String> = []

    /// At launch: starts sending only if the user has said yes.
    static func start(context: [String: String]) {
        guard enabled else { return }
        begin()
        send(.launched, context)
    }

    /// The user's answer, from setup, the one-time question or Settings.
    static func setConsent(_ granted: Bool, context: [String: String] = [:]) {
        consent = granted ? .granted : .declined
        if granted {
            begin()
            send(.launched, context)
        } else {
            config?.analyticsDisabled = true
        }
    }

    static func send(_ event: Event, _ parameters: [String: String] = [:]) {
        guard enabled, started else { return }
        TelemetryDeck.signal(event.rawValue, parameters: parameters)
    }

    /// How Mac TV is being controlled, once per source per launch.
    static func noteInput(_ source: Feedback.Source) {
        guard enabled, inputsSeen.insert(String(describing: source)).inserted else { return }
        send(.inputUsed, ["source": String(describing: source)])
    }

    private static func begin() {
        if let config {
            config.analyticsDisabled = false
            return
        }
        let config = TelemetryDeck.Config(appID: appID)
        // A launch is not a "session" worth counting on its own; Launched carries the context instead.
        config.sendNewSessionBeganSignal = false
        TelemetryDeck.initialize(config: config)
        self.config = config
    }
}

extension TVController {
    /// Anonymous context for the Launched event: settings and counts, never names or what's watched.
    var analyticsContext: [String: String] {
        let builtIn = Set(Catalog.services.map(\.id))
        let onHome = services.filter { builtIn.contains($0.id) && $0.kind != .settings && $0.kind != .addApp }.map(\.id)
        let added = services.filter { !builtIn.contains($0.id) }
        return [
            "builtInApps": onHome.sorted().joined(separator: ","),
            "addedWebsites": String(added.filter { if case .web = $0.kind { true } else { false } }.count),
            "addedMacApps": String(added.filter { if case .app = $0.kind { true } else { false } }.count),
            "addedSteamGames": String(added.filter { if case .steam = $0.kind { true } else { false } }.count),
            "profiles": String(profiles.all.count),
            "phonePaired": String(phonePaired),
            "controllerConnected": String(controller != nil),
            "screenSaver": ScreenSaverSettings.wallpaper.rawValue,
            "sounds": String(Feedback.shared.enabled),
            "keepMacAwake": String(keepMacAwake),
            "lidOverride": String(lidOverride),
            "autoSkip": String(autoSkip),
            "autoNext": String(autoNext),
            "fullScreen": String(window?.styleMask.contains(.fullScreen) ?? false),
            "externalDisplay": String(power.externalDisplay),
        ]
    }

    /// Which app was opened: a built-in app's name (Netflix, YouTube…), otherwise only its kind.
    func analyticsAppName(_ service: Service) -> String {
        if Catalog.services.contains(where: { $0.id == service.id }) { return service.id }
        switch service.kind {
        case .web: return "added-website"
        case .app: return "added-mac-app"
        case .steam: return "steam"
        case .movies, .addApp, .settings: return service.id
        }
    }
}
