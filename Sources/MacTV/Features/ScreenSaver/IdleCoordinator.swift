import Foundation

/// The screen saver after a few idle minutes on the home screen, and the sleep timer.
@MainActor
final class IdleCoordinator: ObservableObject {
    weak var tv: TVController?

    /// Shown after a few idle minutes on the home screen; any input dismisses it.
    @Published private(set) var screensaver = false
    /// When the sleep timer goes off, while it's set.
    @Published private(set) var sleepAt: Date?

    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var sleepTimer: Timer?

    init() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
    }

    /// Any keyboard, mouse or remote input. Returns true when it only woke the screensaver.
    @discardableResult
    func noteActivity() -> Bool {
        lastActivity = Date()
        guard screensaver else { return false }
        screensaver = false
        return true
    }

    private func checkIdle() {
        guard let tv, tv.mode == .launcher, !tv.playbackCoordinator.isAnyPlaybackActive, !tv.displaysSleeping,
              tv.activeSheet == nil, tv.movies == nil, !screensaver,
              Date().timeIntervalSince(lastActivity) > TimeInterval(ScreenSaverSettings.delayMinutes * 60) else { return }
        showScreensaver()
    }

    func showScreensaver() {
        guard tv?.displaysSleeping != true else { return }
        Analytics.send(.screenSaverStarted, ["wallpaper": ScreenSaverSettings.wallpaper.rawValue])
        ScreenSaverSettings.playing = ScreenSaverSettings.pictures(for: ScreenSaverSettings.wallpaper)
        lastActivity = Date()
        screensaver = true
    }

    func hideScreensaver() { screensaver = false }

    /// Stops playback, goes home and turns the screen off after `minutes`; 0 cancels.
    func setSleepTimer(minutes: Int) {
        sleepTimer?.invalidate()
        guard minutes > 0 else {
            sleepAt = nil
            tv?.showToast("Sleep timer off")
            return
        }
        sleepAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleepAt = nil
                self.tv?.goHome()
                SystemControl.displayOff()
            }
        }
        tv?.showToast("Sleep timer: \(minutes) minutes")
    }
}
