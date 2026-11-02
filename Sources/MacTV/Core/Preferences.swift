import Foundation

/// The viewer's settings, saved in UserDefaults under the keys Mac TV has always used.
///
/// They're published, so a screen showing a setting redraws when it changes, wherever it was
/// changed: the TV, the phone remote or Control Center. Features keep their own rules on top, like
/// which screen saver delays are allowed; this only stores the values.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoSkip = defaults.object(forKey: Key.autoSkip) as? Bool ?? true
        autoNext = defaults.object(forKey: Key.autoNext) as? Bool ?? true
        keepMacAwake = defaults.object(forKey: Key.keepMacAwake) as? Bool ?? true
        lidOverride = defaults.bool(forKey: Key.lidOverride)
        navigationSounds = defaults.object(forKey: Key.navigationSounds) as? Bool ?? true
        navigationSoundVolume = defaults.object(forKey: Key.navigationSoundVolume) as? Float ?? 0.7
        automaticUpdates = defaults.object(forKey: Key.automaticUpdates) as? Bool ?? true
        analyticsConsent = defaults.string(forKey: Key.analyticsConsent)
        saverWallpaper = defaults.string(forKey: Key.saverWallpaper)
        saverDelay = defaults.object(forKey: Key.saverDelay) as? Int
        saverClock = defaults.object(forKey: Key.saverClock) as? Bool ?? true
        saverAerialCategory = defaults.string(forKey: Key.saverAerialCategory)
        saverPhotos = defaults.string(forKey: Key.saverPhotos)
        dedicatedTVMode = defaults.bool(forKey: Key.dedicatedTVMode)
        preferredTVDisplay = defaults.string(forKey: Key.preferredTVDisplay)
    }

    // MARK: Watching

    /// Press the players' own Skip Intro and Skip Recap buttons.
    @Published var autoSkip: Bool { didSet { save(autoSkip, Key.autoSkip) } }
    /// Press Next Episode when the player offers it.
    @Published var autoNext: Bool { didSet { save(autoNext, Key.autoNext) } }

    // MARK: Power

    /// Keep the Mac from sleeping on its own while Mac TV is open, so the remote can reach it.
    @Published var keepMacAwake: Bool { didSet { save(keepMacAwake, Key.keepMacAwake) } }
    /// Keep running with the lid closed, even on battery or without a TV connected.
    @Published var lidOverride: Bool { didSet { save(lidOverride, Key.lidOverride) } }

    // MARK: Sounds

    @Published var navigationSounds: Bool { didSet { save(navigationSounds, Key.navigationSounds) } }
    /// 0 to 1.
    @Published var navigationSoundVolume: Float { didSet { save(navigationSoundVolume, Key.navigationSoundVolume) } }

    // MARK: Updates and analytics

    @Published var automaticUpdates: Bool { didSet { save(automaticUpdates, Key.automaticUpdates) } }
    /// `Analytics.Consent`'s raw value; nil until the viewer has been asked.
    @Published var analyticsConsent: String? { didSet { save(analyticsConsent, Key.analyticsConsent) } }

    // MARK: Screen saver

    /// `ScreenSaverSettings.Wallpaper`'s raw value; nil for the default.
    @Published var saverWallpaper: String? { didSet { save(saverWallpaper, Key.saverWallpaper) } }
    /// Minutes; nil for the default.
    @Published var saverDelay: Int? { didSet { save(saverDelay, Key.saverDelay) } }
    @Published var saverClock: Bool { didSet { save(saverClock, Key.saverClock) } }
    /// A live wallpaper category's id; nil plays all of them.
    @Published var saverAerialCategory: String? { didSet { save(saverAerialCategory, Key.saverAerialCategory) } }
    /// The Your Photos folder's path; nil for Pictures.
    @Published var saverPhotos: String? { didSet { save(saverPhotos, Key.saverPhotos) } }

    // MARK: Dedicated TV

    @Published var dedicatedTVMode: Bool { didSet { save(dedicatedTVMode, Key.dedicatedTVMode) } }
    /// The display Mac TV moves to; nil picks one automatically.
    @Published var preferredTVDisplay: String? { didSet { save(preferredTVDisplay, Key.preferredTVDisplay) } }

    private func save(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private enum Key {
        static let autoSkip = "autoSkip"
        static let autoNext = "autoNext"
        static let keepMacAwake = "keepMacAwake"
        static let lidOverride = "lidOverride"
        static let navigationSounds = "uiFeedback"
        static let navigationSoundVolume = "uiFeedbackVolume"
        static let automaticUpdates = "automaticUpdates"
        static let analyticsConsent = "analyticsConsent"
        static let saverWallpaper = "saverWallpaper"
        static let saverDelay = "saverDelay"
        static let saverClock = "saverClock"
        static let saverAerialCategory = "saverAerialCategory"
        static let saverPhotos = "saverPhotos"
        static let dedicatedTVMode = "dedicatedTVMode"
        static let preferredTVDisplay = "preferredTVDisplay"
    }
}
