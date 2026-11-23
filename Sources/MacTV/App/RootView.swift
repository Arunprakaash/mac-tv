import SwiftUI

struct RootView: View {
    @ObservedObject var tv: TVController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Home stays mounted under the launch cover so cancel can reveal it again without rebuilding.
    private var showsHomeCanvas: Bool {
        guard tv.externalBrowser == nil, tv.moviePlayer == nil, tv.movies == nil else { return false }
        if tv.webStarting || tv.webLaunchCanceling { return true }
        if case .player = tv.mode { return false }
        if case .movie = tv.mode { return false }
        return true
    }

    private var homeCoveredByLaunch: Bool {
        tv.webStarting && !tv.webLaunchCanceling
    }

    private var launchCoverActive: Bool {
        tv.webStarting || tv.webLaunchCanceling
    }

    var body: some View {
        ZStack {
            if tv.externalBrowser != nil {
                TVCanvas { BravePlaybackView(tv: tv) }.ignoresSafeArea()
            } else if tv.mode == .movie, let player = tv.moviePlayer {
                MoviePlayerView(tv: tv, player: player).id(ObjectIdentifier(player))
            } else if case .player = tv.mode, let web = tv.webView {
                WebViewHost(webView: web).id(ObjectIdentifier(web))
                    .opacity(tv.webLaunchCanceling || (tv.webStarting && !tv.webContentReady) ? 0 : 1)
                    .animation(Motion.launchExit, value: tv.webContentReady)
                    .allowsHitTesting(tv.playerFailure == nil && !tv.webStarting && !tv.webLaunchCanceling)
                    .accessibilityHidden(tv.playerFailure != nil || tv.webStarting || tv.webLaunchCanceling)
                if tv.playerFailure != nil {
                    TVCanvas { PlaybackFailureView(tv: tv) }.ignoresSafeArea()
                }
            }

            if showsHomeCanvas {
                if !homeCoveredByLaunch && !tv.screensaver {
                    Wallpaper().ignoresSafeArea()
                }
                TVCanvas {
                    ZStack {
                        HomeView(tv: tv)
                            .opacity(homeCoveredByLaunch || tv.screensaver ? 0 : 1)
                            .animation(nil, value: homeCoveredByLaunch)
                            .allowsHitTesting(tv.activeSheet == nil && !tv.screensaver && !launchCoverActive)
                            .accessibilityHidden(tv.activeSheet != nil || tv.screensaver || launchCoverActive)
                        if tv.webStarting, case .player(let service) = tv.mode {
                            WebStartingView(
                                service: service,
                                ready: tv.webContentReady,
                                canceling: tv.webLaunchCanceling,
                                onFinished: { tv.finishWebLaunch() },
                                onCancelled: { tv.completeWebLaunchCancel() }
                            )
                            .allowsHitTesting(false)
                            .accessibilityAddTraits(.updatesFrequently)
                        }
                    }
                }
                .ignoresSafeArea()
                if !launchCoverActive {
                    ModalSheetRouter(tv: tv)
                    if tv.screensaver {
                        TVCanvas { Screensaver() }
                            .ignoresSafeArea()
                            .transition(.opacity.animation(.easeInOut(duration: 1.2)))
                    }
                }
            } else if tv.movies != nil {
                // Opaque, and the only screen drawn, so nothing shows through on the way back from a movie.
                TVCanvas { MoviesScreen(tv: tv) }
                    .ignoresSafeArea()
                    .allowsHitTesting(tv.activeSheet == nil && !tv.screensaver)
                    .accessibilityHidden(tv.activeSheet != nil || tv.screensaver)
                ModalSheetRouter(tv: tv)
            }

            NoticesOverlay(notices: tv.notices)
        }
        .environment(\.colorScheme, .dark)
        .background(Color.black.ignoresSafeArea())
        .animation(Motion.appear, value: tv.sheets.open)
        .animation(Motion.appear, value: tv.movies != nil)
        .animation(.easeInOut(duration: 1.2), value: tv.screensaver)
    }
}

/// Draws the open sheets, bottom to top. Only the top one takes the pointer and VoiceOver.
struct ModalSheetRouter: View {
    @ObservedObject var tv: TVController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ForEach(tv.sheets.open, id: \.self) { layer in
            TVCanvas { sheet(layer) }
                .ignoresSafeArea()
                .allowsHitTesting(tv.isTopSheet(layer))
                .accessibilityHidden(!tv.isTopSheet(layer))
                .background { if layer != .controlCenter { SheetBackdrop() } }
                .transition(transition(layer))
        }
    }

    @ViewBuilder
    private func sheet(_ layer: SheetStack.Layer) -> some View {
        switch layer {
        case .controlCenter: ControlCenterView(tv: tv)
        case .settings: SettingsSheet(tv: tv)
        case .organizer: AppOrganizerSheet(tv: tv)
        case .pairing: PairSheet(tv: tv)
        case .addApp: AddAppSheet(tv: tv)
        case .topShelfPreferences: TopShelfPreferencesSheet(tv: tv)
        case .playbackCheck: PlaybackCheckSheet(tv: tv)
        case .audioPicker: AudioPickerSheet(tv: tv)
        case .profilePicker: ProfilesScreen(tv: tv)
        case .setup: SetupScreen(tv: tv)
        }
    }

    /// Control Center drops from the top like tvOS's; full-screen flows fade; the rest settle in.
    private func transition(_ layer: SheetStack.Layer) -> AnyTransition {
        switch layer {
        case .controlCenter: .move(edge: .top)
        case .profilePicker, .setup: .opacity
        default: Motion.sheet(reduceMotion: reduceMotion)
        }
    }
}
