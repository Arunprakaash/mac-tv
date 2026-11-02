import SwiftUI

struct RootView: View {
    @ObservedObject var tv: TVController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if tv.externalBrowser != nil {
                TVCanvas { BravePlaybackView(tv: tv) }.ignoresSafeArea()
            } else if case .player = tv.mode, let web = tv.webView {
                WebViewHost(webView: web).id(ObjectIdentifier(web))
                    .allowsHitTesting(tv.playerFailure == nil)
                    .accessibilityHidden(tv.playerFailure != nil)
                if tv.playerFailure != nil {
                    TVCanvas { PlaybackFailureView(tv: tv) }.ignoresSafeArea()
                }
            } else if tv.mode == .movie, let player = tv.moviePlayer {
                MoviePlayerView(player: player).id(ObjectIdentifier(player))
            } else {
                if tv.movies != nil {
                    // Opaque, and the only screen drawn, so nothing shows through on the way back from a movie.
                    TVCanvas { MoviesScreen(tv: tv) }
                        .ignoresSafeArea()
                        .allowsHitTesting(tv.activeSheet == nil && !tv.screensaver)
                        .accessibilityHidden(tv.activeSheet != nil || tv.screensaver)
                } else if !tv.screensaver {
                    Wallpaper().ignoresSafeArea()
                    TVCanvas { HomeView(tv: tv) }
                        .ignoresSafeArea()
                        .allowsHitTesting(tv.activeSheet == nil && !tv.screensaver)
                        .accessibilityHidden(tv.activeSheet != nil || tv.screensaver)
                }
                ModalSheetRouter(tv: tv)
                if tv.screensaver {
                    TVCanvas { Screensaver() }
                        .ignoresSafeArea()
                        .transition(.opacity.animation(.easeInOut(duration: 1.2)))
                }
            }

            if let notice = tv.controllerNotice {
                TVCanvas {
                    GlassGroup { ControllerBanner(notice: notice).tvGlassTransition() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.trailing, 96)
                        .padding(.top, 43)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            if let volume = tv.volume {
                TVCanvas {
                    GlassGroup {
                        VolumeHUD(volume: volume).tvGlassTransition()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 96)
                    .padding(.top, 52)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            // Always in place, so the toast's glass materializes in and out rather than fading.
            TVCanvas {
                GlassGroup {
                    if let toast = tv.toast {
                        Text(toast)
                            .font(.tv(.callout))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 34).padding(.vertical, 18)
                            .tvGlass(in: Capsule())
                            .tvGlassTransition()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 52)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
        .background(Color.black.ignoresSafeArea())
        .animation(Motion.appear, value: tv.toast)
        .animation(Motion.appear, value: tv.audioPicker != nil)
        .animation(Motion.appear, value: tv.pairing)
        .animation(Motion.appear, value: tv.settings != nil)
        .animation(Motion.appear, value: tv.organizer != nil)
        .animation(Motion.appear, value: tv.topShelfPreferences != nil)
        .animation(Motion.appear, value: tv.playbackCheck != nil)
        .animation(Motion.appear, value: tv.setup != nil)
        .animation(Motion.appear, value: tv.profilePicker != nil)
        .animation(Motion.appear, value: tv.controlCenter != nil)
        .animation(Motion.appear, value: tv.adder != nil)
        .animation(Motion.appear, value: tv.movies != nil)
        .animation(.easeInOut(duration: 1.2), value: tv.screensaver)
    }
}

/// Routes modal sheets with top-level focus gating and transition animations.
struct ModalSheetRouter: View {
    @ObservedObject var tv: TVController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if tv.controlCenter != nil {
                TVCanvas { ControlCenterView(tv: tv) }
                    .ignoresSafeArea()
                    .allowsHitTesting(tv.isTopSheet(.controlCenter))
                    .accessibilityHidden(!tv.isTopSheet(.controlCenter))
                    .transition(.move(edge: .top))
            }
            if tv.settings != nil {
                TVCanvas { SettingsSheet(tv: tv) }
                    .ignoresSafeArea()
                    .allowsHitTesting(tv.isTopSheet(.settings))
                    .accessibilityHidden(!tv.isTopSheet(.settings))
                    .background { SheetBackdrop() }
                    .transition(Motion.sheet(reduceMotion: reduceMotion))
            }
            if tv.organizer != nil {
                TVCanvas { AppOrganizerSheet(tv: tv) }
                    .ignoresSafeArea()
                    .allowsHitTesting(tv.isTopSheet(.organizer))
                    .accessibilityHidden(!tv.isTopSheet(.organizer))
                    .background { SheetBackdrop() }
                    .transition(Motion.sheet(reduceMotion: reduceMotion))
            }
            if tv.pairing {
                TVCanvas { PairSheet(tv: tv) }
                    .ignoresSafeArea()
                    .allowsHitTesting(tv.isTopSheet(.pairing))
                    .accessibilityHidden(!tv.isTopSheet(.pairing))
                    .background { SheetBackdrop() }
                    .transition(Motion.sheet(reduceMotion: reduceMotion))
            }
            if tv.adder != nil {
                TVCanvas { AddAppSheet(tv: tv) }
                    .ignoresSafeArea()
                    .allowsHitTesting(tv.isTopSheet(.addApp))
                    .accessibilityHidden(!tv.isTopSheet(.addApp))
                    .background { SheetBackdrop() }
                    .transition(Motion.sheet(reduceMotion: reduceMotion))
            }
            if tv.topShelfPreferences != nil {
                TVCanvas { TopShelfPreferencesSheet(tv: tv) }
                    .ignoresSafeArea()
                    .allowsHitTesting(tv.isTopSheet(.topShelfPreferences))
                    .accessibilityHidden(!tv.isTopSheet(.topShelfPreferences))
                    .background { SheetBackdrop() }
                    .transition(Motion.sheet(reduceMotion: reduceMotion))
            }
            if tv.playbackCheck != nil {
                TVCanvas { PlaybackCheckSheet(tv: tv) }
                    .ignoresSafeArea()
                    .allowsHitTesting(tv.isTopSheet(.playbackCheck))
                    .accessibilityHidden(!tv.isTopSheet(.playbackCheck))
                    .background { SheetBackdrop() }
                    .transition(Motion.sheet(reduceMotion: reduceMotion))
            }
            if tv.audioPicker != nil {
                TVCanvas { AudioPickerSheet(tv: tv) }
                    .ignoresSafeArea()
                    .allowsHitTesting(tv.isTopSheet(.audioPicker))
                    .accessibilityHidden(!tv.isTopSheet(.audioPicker))
                    .background { SheetBackdrop() }
                    .transition(Motion.sheet(reduceMotion: reduceMotion))
            }
            if tv.profilePicker != nil {
                TVCanvas { ProfilesScreen(tv: tv) }
                    .ignoresSafeArea()
                    .allowsHitTesting(tv.isTopSheet(.profilePicker))
                    .accessibilityHidden(!tv.isTopSheet(.profilePicker))
                    .background { SheetBackdrop() }
                    .transition(.opacity)
            }
            if tv.setup != nil {
                TVCanvas { SetupScreen(tv: tv) }
                    .ignoresSafeArea()
                    .allowsHitTesting(tv.isTopSheet(.setup))
                    .accessibilityHidden(!tv.isTopSheet(.setup))
                    .background { SheetBackdrop() }
                    .transition(.opacity)
            }
        }
    }
}
