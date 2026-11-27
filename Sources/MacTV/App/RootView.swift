import SwiftUI

struct RootView: View {
    @ObservedObject var tv: TVController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Home stays mounted under the launch cover so cancel can reveal it again without rebuilding.
    private var showsHomeCanvas: Bool {
        // Cover draws over BravePlaybackView / player until hand-off.
        if tv.launchCover != nil { return true }
        guard tv.externalBrowser == nil, tv.moviePlayer == nil, tv.movies == nil else { return false }
        if case .player = tv.mode { return false }
        if case .movie = tv.mode { return false }
        return true
    }

    private var homeCoveredByLaunch: Bool {
        guard let cover = tv.launchCover else { return false }
        return !cover.canceling
    }

    private var launchCoverActive: Bool {
        tv.launchCover != nil
    }

    /// WebView stays hidden until the cover hands off into the page.
    private var webHiddenByLaunch: Bool {
        guard let cover = tv.launchCover, case .player = tv.mode else { return false }
        return cover.canceling || !cover.ready
    }

    var body: some View {
        ZStack {
            if tv.externalBrowser != nil {
                TVCanvas { BravePlaybackView(tv: tv) }.ignoresSafeArea()
            } else if tv.mode == .movie, let player = tv.moviePlayer {
                MoviePlayerView(tv: tv, player: player).id(ObjectIdentifier(player))
            } else if case .player = tv.mode, let web = tv.webView {
                WebViewHost(webView: web).id(ObjectIdentifier(web))
                    .opacity(webHiddenByLaunch ? 0 : 1)
                    .animation(Motion.launchExit, value: tv.launchCover?.ready == true)
                    .allowsHitTesting(tv.playerFailure == nil && !launchCoverActive)
                    .accessibilityHidden(tv.playerFailure != nil || launchCoverActive)
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
                        if let cover = tv.launchCover {
                            LaunchCover(
                                service: cover.service,
                                ready: cover.ready,
                                canceling: cover.canceling,
                                onFinished: { tv.finishLaunchCover() },
                                onCancelled: { tv.completeLaunchCoverCancel() }
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

            // Keep TVCanvas mounted so the slide runs on the dock only — a full-screen
            // `.move(edge: .bottom)` yanks the already-bottom keyboard off in one frame.
            TVCanvas {
                ZStack(alignment: .bottom) {
                    if tv.onScreenKeyboard.isOpen {
                        LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 420)
                            .frame(maxWidth: .infinity)
                            .transition(.opacity)
                        OnScreenKeyboardView(tv: tv, state: tv.onScreenKeyboard)
                            .padding(.bottom, 48)
                            .transition(reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .animation(Motion.appear, value: tv.onScreenKeyboard.isOpen)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
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
