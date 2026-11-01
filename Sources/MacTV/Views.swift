import SwiftUI
import WebKit
import AVFoundation

// The home screen follows Apple TV (tvOS 26): the focused dock app's Top Shelf fills the
// screen behind a frosted glass dock of 5:3 icons, with the next row peeking below. Moving
// up expands the Top Shelf; moving down scrolls into the full app grid. Everything is laid
// out on a canvas 1920 points wide (or 1080 tall, whichever fits), stretched along the
// other axis so it fills any window shape edge to edge.

private struct Layout {
    static let tile = CGSize(width: 250, height: 150)
    static let tileSpacing: CGFloat = 28
    static let dockPadding: CGFloat = 44
    static let rowGap: CGFloat = 80

    let canvas: CGSize

    /// The dock sits a fixed distance from the bottom; extra height goes to the Top Shelf.
    var dockFrame: CGRect { CGRect(x: (canvas.width - 1728) / 2, y: canvas.height - 320, width: 1728, height: 220) }
    /// How far everything moves up when focus goes below the dock.
    var gridShift: CGFloat { dockFrame.midY - Self.tile.height / 2 - 75 }
}

private struct CanvasSizeKey: EnvironmentKey {
    static let defaultValue = CGSize(width: 1920, height: 1080)
}

extension EnvironmentValues {
    /// The TV canvas in points: 1920×1080 at 16:9, taller or wider for other window shapes.
    var canvasSize: CGSize {
        get { self[CanvasSizeKey.self] }
        set { self[CanvasSizeKey.self] = newValue }
    }
}

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
                        .allowsHitTesting(tv.controlCenter == nil && tv.settings == nil && tv.organizer == nil && !tv.pairing && tv.adder == nil && tv.topShelfPreferences == nil && tv.playbackCheck == nil && tv.profilePicker == nil && tv.setup == nil && !tv.screensaver)
                        .accessibilityHidden(tv.controlCenter != nil || tv.settings != nil || tv.organizer != nil || tv.pairing || tv.adder != nil || tv.topShelfPreferences != nil || tv.playbackCheck != nil || tv.profilePicker != nil || tv.setup != nil || tv.screensaver)
                } else if !tv.screensaver {
                    Wallpaper().ignoresSafeArea()
                    TVCanvas { HomeView(tv: tv) }
                        .ignoresSafeArea()
                        .allowsHitTesting(tv.organizer == nil && tv.settings == nil && tv.topShelfPreferences == nil && tv.playbackCheck == nil && !tv.pairing && tv.adder == nil && tv.controlCenter == nil && tv.profilePicker == nil && tv.setup == nil && !tv.screensaver)
                        .accessibilityHidden(tv.organizer != nil || tv.settings != nil || tv.topShelfPreferences != nil || tv.playbackCheck != nil || tv.pairing || tv.adder != nil || tv.controlCenter != nil || tv.profilePicker != nil || tv.setup != nil || tv.screensaver)
                }
                if tv.controlCenter != nil {
                    TVCanvas { ControlCenterView(tv: tv) }
                        .ignoresSafeArea()
                        .allowsHitTesting(tv.settings == nil && tv.organizer == nil && !tv.pairing && tv.adder == nil && tv.topShelfPreferences == nil && tv.playbackCheck == nil && tv.profilePicker == nil && tv.setup == nil && !tv.screensaver)
                        .accessibilityHidden(tv.settings != nil || tv.organizer != nil || tv.pairing || tv.adder != nil || tv.topShelfPreferences != nil || tv.playbackCheck != nil || tv.profilePicker != nil || tv.setup != nil || tv.screensaver)
                        .transition(.move(edge: .top))
                }
                if tv.settings != nil {
                    TVCanvas { SettingsSheet(tv: tv) }
                        .ignoresSafeArea()
                        .allowsHitTesting(tv.organizer == nil && !tv.pairing && tv.adder == nil && tv.topShelfPreferences == nil && tv.playbackCheck == nil && tv.profilePicker == nil && tv.setup == nil && !tv.screensaver)
                        .accessibilityHidden(tv.organizer != nil || tv.pairing || tv.adder != nil || tv.topShelfPreferences != nil || tv.playbackCheck != nil || tv.profilePicker != nil || tv.setup != nil || tv.screensaver)
                        .background { SheetBackdrop() }
                        .transition(Motion.sheet(reduceMotion: reduceMotion))
                }
                if tv.organizer != nil {
                    TVCanvas { AppOrganizerSheet(tv: tv) }
                        .ignoresSafeArea()
                        .allowsHitTesting(!tv.pairing && tv.adder == nil && tv.topShelfPreferences == nil && tv.playbackCheck == nil && tv.profilePicker == nil && tv.setup == nil && !tv.screensaver)
                        .accessibilityHidden(tv.pairing || tv.adder != nil || tv.topShelfPreferences != nil || tv.playbackCheck != nil || tv.profilePicker != nil || tv.setup != nil || tv.screensaver)
                        .background { SheetBackdrop() }
                        .transition(Motion.sheet(reduceMotion: reduceMotion))
                }
                if tv.pairing {
                    TVCanvas { PairSheet(tv: tv) }
                        .ignoresSafeArea()
                        .allowsHitTesting(tv.adder == nil && tv.topShelfPreferences == nil && tv.playbackCheck == nil && tv.profilePicker == nil && tv.setup == nil && !tv.screensaver)
                        .accessibilityHidden(tv.adder != nil || tv.topShelfPreferences != nil || tv.playbackCheck != nil || tv.profilePicker != nil || tv.setup != nil || tv.screensaver)
                        .background { SheetBackdrop() }
                        .transition(Motion.sheet(reduceMotion: reduceMotion))
                }
                if tv.adder != nil {
                    TVCanvas { AddAppSheet(tv: tv) }
                        .ignoresSafeArea()
                        .allowsHitTesting(tv.topShelfPreferences == nil && tv.playbackCheck == nil && tv.profilePicker == nil && tv.setup == nil && !tv.screensaver)
                        .accessibilityHidden(tv.topShelfPreferences != nil || tv.playbackCheck != nil || tv.profilePicker != nil || tv.setup != nil || tv.screensaver)
                        .background { SheetBackdrop() }
                        .transition(Motion.sheet(reduceMotion: reduceMotion))
                }
                if tv.topShelfPreferences != nil {
                    TVCanvas { TopShelfPreferencesSheet(tv: tv) }
                        .ignoresSafeArea()
                        .allowsHitTesting(tv.playbackCheck == nil && tv.profilePicker == nil && tv.setup == nil && !tv.screensaver)
                        .accessibilityHidden(tv.playbackCheck != nil || tv.profilePicker != nil || tv.setup != nil || tv.screensaver)
                        .background { SheetBackdrop() }
                        .transition(Motion.sheet(reduceMotion: reduceMotion))
                }
                if tv.playbackCheck != nil {
                    TVCanvas { PlaybackCheckSheet(tv: tv) }
                        .ignoresSafeArea()
                        .allowsHitTesting(tv.profilePicker == nil && tv.setup == nil && !tv.screensaver)
                        .accessibilityHidden(tv.profilePicker != nil || tv.setup != nil || tv.screensaver)
                        .background { SheetBackdrop() }
                        .transition(Motion.sheet(reduceMotion: reduceMotion))
                }
                if tv.profilePicker != nil {
                    TVCanvas { ProfilesScreen(tv: tv) }
                        .ignoresSafeArea()
                        .allowsHitTesting(tv.setup == nil && !tv.screensaver)
                        .accessibilityHidden(tv.setup != nil || tv.screensaver)
                        .background { SheetBackdrop() }
                        .transition(.opacity)
                }
                if tv.setup != nil {
                    TVCanvas { SetupScreen(tv: tv) }
                        .ignoresSafeArea()
                        .allowsHitTesting(!tv.screensaver)
                        .accessibilityHidden(tv.screensaver)
                        .background { SheetBackdrop() }
                        .transition(.opacity)
                }
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

/// Apple-style screensaver: Apple's own aerial films when the Mac has downloaded them
/// (System Settings › Wallpaper or Screen Saver), otherwise slow-drifting colour, under a large
/// lock-screen clock at the top centre.
struct Screensaver: View {
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        ZStack(alignment: .top) {
            ScreenSaverBackdrop(wallpaper: ScreenSaverSettings.wallpaper, pictures: ScreenSaverSettings.playing)
            if ScreenSaverSettings.showClock {
                // Keeps the clock legible over bright skies.
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .center)

                TimelineView(.everyMinute) { context in
                    VStack(spacing: 0) {
                        Text(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.tv(.callout))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(context.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                            .font(.system(size: 230, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.92))
                            .tracking(-4)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 6)
                    .padding(.top, 70)
                }
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }
}

/// Plays aerial films one after another, muted and filling the screen.
struct AerialPlayer: NSViewRepresentable {
    let films: [URL]

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let player = AVQueuePlayer(items: (films + films).map { AVPlayerItem(url: $0) })
        player.isMuted = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = layer
        player.play()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView.layer as? AVPlayerLayer)?.player?.pause()
    }
}

/// Lays content out on a TV canvas and scales it to the window, like a TV UI. The canvas is
/// 1920 wide on screens taller than 16:9 and 1080 tall on wider ones, so it always fills the
/// window with no bars.
struct TVCanvas<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let window = CGSize(width: max(geo.size.width, 1), height: max(geo.size.height, 1))
            let scale = window.width / window.height < 16 / 9 ? window.width / 1920 : window.height / 1080
            let canvas = CGSize(width: window.width / scale, height: window.height / scale)
            content
                .environment(\.canvasSize, canvas)
                .frame(width: canvas.width, height: canvas.height)
                .scaleEffect(scale)
                .frame(width: window.width, height: window.height)
        }
    }
}

struct Wallpaper: View {
    var body: some View {
        RadialGradient(colors: [Color(hex: "#1B1E27"), Color(hex: "#0A0B0E")],
                       center: .top, startRadius: 0, endRadius: 1300)
    }
}

// MARK: Home

struct HomeView: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas
    @Namespace private var pills

    private var shelfFocused: Bool {
        // The status row sits above the Top Shelf, so the banner stays open while it has focus.
        switch tv.focus {
        case .shelf, .status: return true
        case .app: return false
        }
    }

    private var focusedRow: Int {
        if case .app(let index) = tv.focus { return index / tv.columns }
        return 0
    }

    var body: some View {
        let layout = Layout(canvas: canvas)
        let rowStride = Layout.tile.height + Layout.rowGap
        // Dock (row 0) sits at rest; row 1 brings the grid up; each subsequent row scrolls by rowStride.
        let gridOffset: CGFloat = shelfFocused ? 420 : (focusedRow > 0 ? -layout.gridShift - CGFloat(focusedRow - 1) * rowStride : 0)

        ZStack(alignment: .topLeading) {
            TopShelf(tv: tv, expanded: shelfFocused)
                .offset(y: gridOffset < 0 ? gridOffset : 0)
                .opacity(tv.inGrid ? 0 : 1)

            AppGrid(tv: tv)
                // An expanded banner takes the whole screen; the dock slides away, off the bottom.
                .offset(y: gridOffset)

            if !tv.inGrid && !shelfFocused && tv.shelfCount > 0 {
                Image(systemName: "chevron.compact.up")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .position(x: canvas.width / 2, y: layout.dockFrame.minY - 30)
                    .transition(.opacity)
            }

            // The status row: always the same pills, Control Center or not. Up from the Top Shelf focuses it;
            // Left and Right move along it, skipping the clock.
            GlassGroup { HStack(spacing: 14) {
                // While the Mac can't sleep with its lid closed, say so where it's always seen.
                if tv.lidSleepOff {
                    let focused = tv.focus == .status(.lid)
                    Label("Lid sleep off", systemImage: "moon.zzz")
                        .font(.tv(.caption2))
                        .padding(.horizontal, 20)
                        .frame(height: 50)
                        .foregroundStyle(focused ? .black : .white)
                        .focusPlatter(Capsule(), focused: focused)
                        .contentShape(Capsule())
                        .onTapGesture { tv.activateStatus(.lid) }
                        .tvGlassID("lid", in: pills)
                }
                if let controller = tv.controller {
                    ControllerHints(info: controller).tvGlassID("controller", in: pills)
                }
                // Control Center: white while it's open or focused, like Apple TV's.
                let lit = tv.focus == .status(.controlCenter) || tv.controlCenter != nil
                Image(systemName: "switch.2")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(lit ? .black : .white)
                    .frame(width: 50, height: 50)
                    .focusPlatter(Circle(), focused: lit)
                    .contentShape(Circle())
                    .onTapGesture { tv.controlCenter == nil ? tv.activateStatus(.controlCenter) : (tv.controlCenter = nil) }
                    .tvGlassID("control-center", in: pills)
                ClockPill().tvGlassID("clock", in: pills)
                let profileFocused = tv.focus == .status(.profile)
                ProfileAvatar(profile: tv.profile, size: 50)
                    .overlay(Circle().strokeBorder(.white, lineWidth: profileFocused ? 3 : 0).padding(-5))
                    .contentShape(Circle())
                    .onTapGesture { tv.activateStatus(.profile) }
            } }
                .animation(Motion.focus, value: tv.focus)
                .animation(Motion.appear, value: tv.lidSleepOff)
                .animation(Motion.appear, value: tv.controller)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 96)
                .padding(.top, 56)
                // Out of the way while the grid, the volume or a controller banner has the corner. It slides up
                // off the screen rather than fading, so the glass never goes translucent.
                .offset(y: tv.inGrid || tv.volume != nil || tv.controllerNotice != nil ? -200 : 0)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
        .foregroundStyle(.white)
        .animation(Motion.navigate, value: focusedRow)
        .animation(Motion.navigate, value: shelfFocused)
        .animation(Motion.appear, value: tv.shelfAppIndex)
    }
}

struct ClockPill: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(context.date.formatted(date: .omitted, time: .shortened))
                .font(.tv(.caption1))
                .monospacedDigit()
                .padding(.horizontal, 20)
                .frame(height: 50)
                .tvGlass(in: Capsule())
        }
    }
}

// MARK: Dock and app grid

struct AppGrid: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let layout = Layout(canvas: canvas)
        // Each cell carries its own app, keyed by id, so a cell never reads a list that has
        // since changed (removing an app shortens it).
        let cells = tv.services.enumerated().map { AppCell.Item(index: $0.offset, service: $0.element) }
        let rows = stride(from: 0, to: cells.count, by: tv.columns).map {
            Array(cells[$0..<min($0 + tv.columns, cells.count)])
        }
        ZStack(alignment: .topLeading) {
            GlassDock(visible: !tv.inGrid)
                .frame(width: layout.dockFrame.width, height: layout.dockFrame.height)
                .offset(x: layout.dockFrame.minX, y: layout.dockFrame.minY)

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: Layout.tileSpacing) {
                    ForEach(row) { item in
                        AppCell(tv: tv, item: item, showsLabel: rowIndex > 0 || tv.inGrid)
                    }
                }
                .offset(x: layout.dockFrame.minX + Layout.dockPadding, y: top(ofRow: rowIndex, in: layout))
            }
        }
    }

    private func top(ofRow row: Int, in layout: Layout) -> CGFloat {
        let dockRowTop = layout.dockFrame.midY - Layout.tile.height / 2
        guard row > 0 else { return dockRowTop }
        // The second row peeks just below the dock.
        return layout.dockFrame.maxY + 60 + CGFloat(row - 1) * (Layout.tile.height + Layout.rowGap)
    }
}

/// tvOS 26 dock: frosted Liquid Glass with a lit top edge.
struct GlassDock: View {
    /// In the grid the dock's glass dissolves to nothing (`.identity`) instead of fading, which would flatten it.
    var visible = true

    var body: some View {
        Color.clear
            .shadow(color: .black.opacity(visible ? 0.25 : 0), radius: 30, y: 16)
            .tvGlass(in: RoundedRectangle(cornerRadius: 48, style: .continuous), enabled: visible)
    }
}

/// The frosted backdrop behind full-screen sheets (Settings, Add App, Profiles, Setup): the home screen
/// blurred and dimmed. Sheets on it use plain panels and platters, not glass.
struct SheetBackdrop: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            Rectangle().fill(.ultraThinMaterial)
        }
        .ignoresSafeArea()
    }
}

struct AppCell: View {
    struct Item: Identifiable {
        let index: Int
        let service: Service
        var id: String { service.id }
    }

    @ObservedObject var tv: TVController
    let item: Item
    let showsLabel: Bool

    var body: some View {
        let index = item.index, service = item.service
        let focused = tv.focus == .app(index)
        AppTile(service: service, focused: focused, tilt: focused ? tv.tilt : .zero)
            .overlay(alignment: .topTrailing) {
                if tv.isPinned(service.id) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.yellow)
                        .padding(9)
                        .background(.black.opacity(0.7), in: Circle())
                        .padding(10)
                        .accessibilityLabel("Favourite")
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                Text(service.name)
                    .font(.tv(.caption1))
                    .fixedSize()
                    .offset(y: 50)
                    .opacity(focused && showsLabel ? 1 : 0)
                    .offset(y: focused && showsLabel ? 0 : -8)
                    .animation(Motion.focus, value: focused)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    tv.hover(index, tilt: CGSize(width: location.x / Layout.tile.width - 0.5,
                                                 height: location.y / Layout.tile.height - 0.5))
                case .ended:
                    tv.tilt = .zero
                }
            }
            .onTapGesture {
                tv.setFocus(.app(index))
                tv.open(service)
            }
            .zIndex(focused ? 1 : 0)
    }
}

struct AppTile: View {
    let service: Service
    let focused: Bool
    let tilt: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let tilt = reduceMotion ? .zero : tilt
        artwork
            .frame(width: Layout.tile.width, height: Layout.tile.height)
            .clipShape(shape)
            // tvOS light: a soft glare on the focused tile that slides with the pointer.
            .overlay {
                RadialGradient(colors: [.white.opacity(0.32), .white.opacity(0)],
                               center: UnitPoint(x: 0.5 + tilt.width * 1.2, y: 0.05 + tilt.height * 1.2),
                               startRadius: 0, endRadius: Layout.tile.width * 0.75)
                    .blendMode(.plusLighter)
                    .clipShape(shape)
                    .opacity(focused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            // A glass edge: a faint rim at rest, a bright top highlight when focused.
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(focused ? 0.55 : 0.14), .white.opacity(focused ? 0.08 : 0.03)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: focused ? 1.5 : 1)
            }
            .rotation3DEffect(.degrees(-tilt.height * 10), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tilt.width * 12), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .scaleEffect(focused ? (reduceMotion ? 1.06 : 1.14) : 1)
            .offset(y: focused && !reduceMotion ? -10 : 0)
            // Resting icons sit flat on the glass; only the focused one casts a shadow.
            .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: focused ? 28 : 0, y: focused ? 24 : 0)
            .animation(Motion.focus, value: focused)
            .animation(Motion.tilt, value: tilt)
    }

    @ViewBuilder private var artwork: some View {
        if case .addApp = service.kind {
            ZStack {
                Color.white.opacity(0.08)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                Image(systemName: "plus")
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        } else if case .movies = service.kind {
            ZStack {
                LinearGradient(colors: [Color(hex: "#5E5CE6"), Color(hex: "#1F1A6B")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "film.stack")
                    .font(.system(size: 70, weight: .medium))
                    .foregroundStyle(.white)
            }
        } else if case .settings = service.kind {
            ZStack {
                LinearGradient(colors: [Color(hex: "#8E8E93"), Color(hex: "#3A3A3C")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 76))
                    .foregroundStyle(.white)
            }
        } else if let tile = Icons.tile(for: service) {
            Image(nsImage: tile).resizable().interpolation(.high)
        } else {
            ZStack {
                Color(hex: "#2C2C2E")
                Text(service.name).font(.tv(.body, emphasized: true))
            }
        }
    }
}

// MARK: Top Shelf

struct TopShelf: View {
    @ObservedObject var tv: TVController
    let expanded: Bool
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let service = tv.shelfService
        Group {
            if tv.shelfCount > 0 {
                AppBanner(tv: tv, service: service, expanded: expanded)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .id(service.id)
        .transition(.opacity)
    }
}

/// The focused app's colours across the screen, with its name top-left. Moving up from the
/// dock brings up Open. Nothing about what was watched ever shows here.
struct AppBanner: View {
    @ObservedObject var tv: TVController
    @ObservedObject private var feed = TopShelfFeed.shared
    @ObservedObject private var movieLibrary = MovieLibrary.shared
    @Environment(\.canvasSize) private var canvas
    let service: Service
    let expanded: Bool

    /// What the Top Shelf shows now: the Movies app's own movies, or the app's popular shows.
    private var backdrop: (id: String, name: String, image: NSImage, cover: Bool)? {
        if case .movies = service.kind {
            let shelf = movieLibrary.shelf
            if !shelf.isEmpty {
                let pick = shelf[feed.turn % shelf.count]
                // Posters sit on the right like album covers; frames from the film fill the screen.
                return (pick.path, movieLibrary.movies.first(where: { $0.path == pick.path })?.displayTitle ?? "Movies", pick.image, pick.image.size.height > pick.image.size.width)
            }
        }
        guard let show = feed.currentShow(for: service.id) else { return nil }
        return feed.image(for: show.id).map { (String(show.id), show.name, $0, show.square) }
    }

    var body: some View {
        let show = backdrop
        ZStack(alignment: .topLeading) {
            Artwork(accent: service.accent, deep: service.deep)
                .frame(width: canvas.width, height: canvas.height)
                .clipped()
            // Popular shows on this app, cross-fading one to the next, like Apple TV's Top Shelf.
            if let show {
                if show.cover {
                    AlbumBackdrop(image: show.image)
                        .id(show.id)
                        .transition(.opacity)
                } else {
                    // One view for every show: it cross-fades to the next picture itself, in Core Animation.
                    ShowBackdrop(image: show.image, since: feed.turnStarted)
                }
            }
            // Legibility: a soft top-left wash for the name, a bottom wash for the dock or button.
            LinearGradient(stops: [.init(color: .black.opacity(expanded ? 0.8 : (show == nil ? 0.55 : 0.18)), location: 0),
                                   .init(color: .black.opacity(expanded ? 0.4 : 0.15), location: 0.4),
                                   .init(color: .clear, location: 0.65)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.45),
                                   .init(color: .black.opacity(show == nil ? 0.75 : 0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            if show != nil {
                LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .top, endPoint: .center)
            }

            VStack(alignment: .leading, spacing: 12) {
                if show == nil {
                    // The show's artwork alone carries it; nothing is drawn over it. Without art, the app's name.
                    Text(service.name)
                        .font(.tv(.title1, emphasized: true))
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                }
                if expanded {
                    HStack(spacing: 18) {
                        if feed.searchURL(for: service) != nil {
                            ShelfButton(title: "Search in \(service.name)", systemImage: "magnifyingglass", focused: tv.focus == .shelf(0)) {
                                tv.setFocus(.shelf(0)); tv.activateShelf(0)
                            }
                        }
                        let openIndex = feed.searchURL(for: service) == nil ? 0 : 1
                        ShelfButton(title: "Open \(service.name)", systemImage: "arrow.up.right", focused: tv.focus == .shelf(openIndex)) {
                            tv.setFocus(.shelf(openIndex)); tv.activateShelf(openIndex)
                        }
                    }
                    .padding(.top, 20)
                    .tvGlassTransition()
                }
            }
            .frame(width: 1100, alignment: .leading)
            .padding(.leading, 96)
            .frame(maxHeight: .infinity, alignment: expanded ? .bottomLeading : .topLeading)
            .padding(.top, 96)
            .padding(.bottom, 110)
        }
    }
}

/// tvOS buttons: glass at rest, white with dark text when focused.
struct ShelfButton: View {
    let title: String
    var systemImage: String? = nil
    let focused: Bool
    /// Glass over artwork, like the Top Shelf; a plain platter on a frosted sheet, where glass has nothing to refract.
    var glass = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.tv(.callout, emphasized: true))
            .padding(.horizontal, 38)
            .frame(height: 72)
            .foregroundStyle(focused ? .black : .white)
            .background {
                if !glass { Capsule().fill(.white.opacity(0.12)) }
            }
            .focusPlatter(Capsule(), focused: focused, glass: glass)
            .scaleEffect(focused ? 1.08 : 1)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 20, y: 14)
            .animation(Motion.focus, value: focused)
        }
        .buttonStyle(.plain)
    }
}

/// A still in the app's own colours, behind the Top Shelf and its cards. Pictures of what you
/// played aren't shown on the home screen.
struct Artwork: View {
    let accent: String
    let deep: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: deep), Color(hex: "#050608")], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(hex: accent).opacity(0.8), Color(hex: accent).opacity(0.2), .clear],
                           center: UnitPoint(x: 0.74, y: 0.28), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [Color(hex: accent).opacity(0.36), .clear],
                           center: UnitPoint(x: 0.56, y: 0.62), startRadius: 0, endRadius: 420)
        }
    }
}

// MARK: Settings › Remote

struct PairSheet: View {
    @Environment(\.canvasSize) private var canvas
    @ObservedObject var tv: TVController

    var body: some View {
        let links = tv.pairingGuest ? tv.remoteGuestLinks : tv.remoteLinks
        HStack(alignment: .center, spacing: 52) {
            HStack(spacing: 24) {
                if links.isEmpty {
                    RoundedRectangle(cornerRadius: 28).fill(.white.opacity(0.1))
                        .frame(width: 300, height: 300)
                        .overlay(Text("Connect to Wi-Fi\nor Tailscale").multilineTextAlignment(.center)
                            .font(.tv(.caption2)).opacity(0.7))
                }
                ForEach(links) { link in
                    VStack(spacing: 14) {
                        if let qr = link.qr {
                            Image(nsImage: qr).interpolation(.none).resizable()
                                .frame(width: 260, height: 260)
                                .padding(20)
                                .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        }
                        Text(link.label).font(.tv(.caption2)).opacity(0.8)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 18) {
                Text("Use your phone as a remote").font(.tv(.title3, emphasized: true))
                Text("Scan with your phone's camera. Code \(tv.pairingGuest ? tv.remoteGuestToken : tv.remoteToken)")
                    .font(.tv(.caption2)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                VStack(spacing: 10) {
                    pairRow("Phone access", value: tv.pairingGuest ? "Guest, 24 hours" : "Full",
                            focused: tv.pairingFocusedRow == .access) { tv.pairingGuest.toggle() }
                    if tv.pairingRows.contains(.display) {
                        let displays = tv.availableTVDisplays
                        pairRow("Display", value: (displays.first(where: \.current) ?? displays.first)?.name,
                                focused: tv.pairingFocusedRow == .display) { tv.stepPairingDisplay() }
                    }
                }
                .padding(.top, 8)
                ShelfButton(title: "Done", focused: tv.pairingFocusedRow == .done, glass: false) { tv.pairing = false }
                    .padding(.top, 10)
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
        .padding(56)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
    }

    /// A row on the frosted sheet: a plain fill at rest, the white platter with dark text when focused.
    private func pairRow(_ title: String, value: String? = nil, focused: Bool,
                         action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return Button(action: action) {
            HStack(spacing: 16) {
                Text(title).lineLimit(1)
                Spacer(minLength: 16)
                if let value { Text(value).opacity(0.6) }
            }
            .font(.tv(.callout))
            .padding(.horizontal, 26)
            .frame(height: 66)
            .foregroundStyle(focused ? .black : .white)
            .background { if !focused { shape.fill(.white.opacity(0.07)) } }
            .focusPlatter(shape, focused: focused, glass: false)
            .scaleEffect(focused ? 1.03 : 1)
            .animation(Motion.focus, value: focused)
        }
        .buttonStyle(.plain)
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Mac TV's motion, built from Apple's system springs so everything moves with one feel.
/// With Reduce Motion on, views fade instead of moving, scaling or tilting.
enum Motion {
    /// Focus moving between tiles, rows and buttons. The same curve and length as `navigate`, so a
    /// focused tile lifts in step with its row scrolling, instead of moving on its own.
    static let focus = Animation.smooth(duration: 0.32)
    /// Scrolling between the Top Shelf, dock and grid.
    static let navigate = Animation.smooth(duration: 0.32)
    /// Sheets, toasts and pills arriving and leaving.
    static let appear = Animation.smooth(duration: 0.35)
    /// A control pressed: quick, settling without a bounce.
    static let press = Animation.smooth(duration: 0.18)
    /// Tiles following the pointer.
    static let tilt = Animation.interactiveSpring(response: 0.25, dampingFraction: 0.85)

    /// A sheet settles into place from slightly larger, like tvOS modals.
    static func sheet(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.04)),
                                              removal: .opacity.combined(with: .scale(scale: 1.02)))
    }
}

extension View {
    /// Apple TV's Liquid Glass, for Mac TV's controls layer only: sheets, the dock, pills,
    /// buttons and the volume indicator, never content. Following Apple's guidance it's the
    /// regular variant (these carry text), applied after the view's other appearance
    /// modifiers; `interactive` makes a control respond to the pointer, and `tint` marks
    /// prominence, like a focused button. Frosted material before macOS 26.
    /// `enabled: false` keeps the modifier in place as `.identity`, so switching glass off never changes the view's identity.
    @ViewBuilder
    func tvGlass<S: InsettableShape>(in shape: S, interactive: Bool = false, tint: Color? = nil, enabled: Bool = true) -> some View {
        if #available(macOS 26, *) {
            glassEffect(enabled ? .regular.tint(tint).interactive(interactive) : .identity, in: shape)
        } else if enabled {
            background(tint ?? .clear, in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.18)))
        } else {
            self
        }
    }

    /// tvOS focus on a control: a solid white platter when focused, the control's glass otherwise. Tinting the
    /// glass white instead reads milky grey over dark artwork, and dark text on it loses contrast. The glass
    /// switches to `.identity` rather than going away, so focus moving never changes the view's identity.
    func focusPlatter<S: InsettableShape>(_ shape: S, focused: Bool, color: Color = .white, glass: Bool = true) -> some View {
        background { shape.fill(color).opacity(focused ? 1 : 0) }
            .tvGlass(in: shape, enabled: glass && !focused)
    }

    /// A plain panel for sheets that sit on the frosted backdrop. Glass there would have only blur to
    /// refract and read as a flat grey slab, so these group their content with a quiet fill instead.
    func tvPanel<S: InsettableShape>(in shape: S) -> some View {
        background(.white.opacity(0.07), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.12)))
    }

    /// Related glass in one GlassGroup morphs between shapes when one appears or leaves.
    @ViewBuilder
    func tvGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// Glass appearing and disappearing materializes, as Apple recommends, rather than fading.
    @ViewBuilder
    func tvGlassTransition() -> some View {
        if #available(macOS 26, *) {
            glassEffectTransition(.materialize)
        } else {
            transition(.opacity)
        }
    }
}

/// Groups nearby glass so it renders in one pass and samples the same backdrop (GlassEffectContainer);
/// a plain stack before macOS 26. `spacing` is how close two shapes must come before they melt into
/// one another: 0 keeps every shape separate, so a focused tile growing or a pressed button
/// shrinking never pulls its neighbours' glass towards it. Raise it only where merging is the point.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Apple TV's volume indicator: a glass capsule with the speaker and the level.
struct VolumeHUD: View {
    let volume: VolumeLevel

    private var symbol: String {
        guard let level = volume.level else { return "tv" }
        if volume.muted || level == 0 { return "speaker.slash.fill" }
        return level < 34 ? "speaker.wave.1.fill" : level < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40)
            if let level = volume.level {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white)
                            .frame(width: geo.size.width * CGFloat(volume.muted ? 0 : level) / 100)
                    }
                }
                .frame(width: 260, height: 8)
            } else {
                Text("Volume is set on the TV").font(.tv(.caption2))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .frame(height: 72)
        .animation(.smooth(duration: 0.2), value: volume)
        .tvGlass(in: Capsule())
    }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

// MARK: Add an app, on the TV

struct AddAppSheet: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas
    @Namespace private var focusSpace

    var body: some View {
        let a = tv.adder ?? AppAdder()
        VStack(alignment: .leading, spacing: 26) {
            Text("Add an app").font(.tv(.title3, emphasized: true))

            HStack(spacing: 6) {
                tab("Website", .website, a)
                tab("Mac app", .macApp, a)
                if tv.adderTabs.contains(.steam) { tab("Steam", .steam, a) }
            }
            .padding(6)
            .background(.white.opacity(a.row == 0 ? 0.22 : 0.08), in: Capsule())
            .scaleEffect(a.row == 0 ? 1.03 : 1)

            if a.tab == .website {
                AdderField(label: "Website", text: a.address, placeholder: "e.g. crunchyroll.com", focused: a.row == 1) { set(row: 1) }
                AdderField(label: "Name (optional)", text: a.name, placeholder: "Taken from the website", focused: a.row == 2) { set(row: 2) }
                ShelfButton(title: "Add to Home Screen", systemImage: "plus", focused: a.row == 3, glass: false) {
                    set(row: 3)
                    tv.submitAdder()
                }
            } else if a.tab == .macApp {
                AdderField(label: "Search apps on this Mac", text: a.query, placeholder: "Type to filter", focused: a.row == 1) { set(row: 1) }
                macList(a)
            } else {
                steamList(a)
            }

            Text(a.message ?? (a.tab == .steam ? "Games open through Steam, and Mac TV comes back when you quit. Esc or Back closes."
                                                : "Type with the keyboard or the remote's typing box. Esc or Back closes."))
                .font(.tv(.caption2, emphasized: a.message != nil))
                .foregroundStyle(a.failed ? Color(hex: "#FF8A80") : .white.opacity(a.message == nil ? 0.55 : 0.9))
        }
        .padding(56)
        .frame(width: 1100, alignment: .leading)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.focus, value: a)
    }

    private func set(row: Int) {
        tv.adder?.row = row
    }

    private func tab(_ title: String, _ tab: AppAdder.Tab, _ a: AppAdder) -> some View {
        let on = a.tab == tab
        return Text(title)
            .font(.tv(.caption1, emphasized: true))
            .padding(.horizontal, 30)
            .frame(height: 54)
            .foregroundStyle(on ? .black : .white)
            .background {
                if on { Capsule().fill(.white).matchedGeometryEffect(id: "tab", in: focusSpace) }
            }
            .contentShape(Capsule())
            .onTapGesture {
                tv.adder?.tab = tab
                tv.adder?.row = 1
                tv.adder?.selected = 0
            }
    }

    /// Steam Big Picture and the installed games, eight rows at a time. Games launch through Steam.
    @ViewBuilder private func steamList(_ a: AppAdder) -> some View {
        let games = tv.adderSteamGames
        let window = 8
        let start = min(max(0, a.selected - window / 2), max(0, games.count - window))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(games.enumerated().dropFirst(start).prefix(window)), id: \.element.appID) { index, game in
                let focused = a.row == 1 && a.selected == index
                let added = tv.isOnHomeScreen(game)
                HStack(spacing: 18) {
                    Group {
                        if game == SteamLibrary.bigPicture, let url = SteamLibrary.appURL {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                        } else {
                            Image(systemName: "gamecontroller.fill").font(.system(size: 24)).frame(width: 44, height: 44)
                        }
                    }
                    .frame(width: 44, height: 44)
                    Text(game.name).font(.tv(.body)).lineLimit(1)
                    Spacer()
                    if added { Text("On TV").font(.tv(.caption2, emphasized: true)).opacity(0.6) }
                }
                .padding(.horizontal, 18)
                .frame(height: 60)
                .foregroundStyle(focused ? .black : .white)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                    if focused {
                        shape.fill(.white).matchedGeometryEffect(id: "focus", in: focusSpace)
                    } else {
                        shape.fill(.white.opacity(0.06))
                    }
                }
                .opacity(added && !focused ? 0.55 : 1)
                .contentShape(Rectangle())
                .onTapGesture {
                    tv.adder?.row = 1
                    tv.adder?.selected = index
                    tv.addSelectedSteamGame()
                }
            }
            if games.count == 1 {
                Text("No Steam games installed yet. Install some in Steam and they'll show up here.")
                    .font(.tv(.caption2)).opacity(0.6).padding(.top, 6)
            }
        }
    }

    /// Eight rows at a time, scrolled to keep the highlighted app in view.
    @ViewBuilder private func macList(_ a: AppAdder) -> some View {
        let matches = tv.adderMatches
        let window = 8
        let start = min(max(0, a.selected - window / 2), max(0, matches.count - window))
        VStack(spacing: 6) {
            if matches.isEmpty {
                Text("No apps match.").font(.tv(.caption1)).opacity(0.6)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            }
            ForEach(Array(matches.enumerated().dropFirst(start).prefix(window)), id: \.element.bundleID) { index, app in
                let focused = a.row == 2 && a.selected == index
                let added = tv.isOnHomeScreen(app)
                HStack(spacing: 18) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable().frame(width: 44, height: 44)
                    Text(app.name).font(.tv(.body)).lineLimit(1)
                    Spacer()
                    if added {
                        Text("On TV").font(.tv(.caption2, emphasized: true)).opacity(0.6)
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: 60)
                .foregroundStyle(focused ? .black : .white)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                    if focused {
                        shape.fill(.white).matchedGeometryEffect(id: "focus", in: focusSpace)
                    } else {
                        shape.fill(.white.opacity(0.06))
                    }
                }
                .opacity(added && !focused ? 0.55 : 1)
                .contentShape(Rectangle())
                .onTapGesture {
                    tv.adder?.row = 2
                    tv.adder?.selected = index
                    tv.addSelectedMacApp()
                }
            }
        }
    }
}

/// A text field drawn for the TV: typed into by the D-pad flow, with a blinking caret when focused.
struct AdderField: View {
    let label: String
    let text: String
    let placeholder: String
    let focused: Bool
    let tap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.tv(.caption2, emphasized: true)).tracking(1).textCase(.uppercase).opacity(0.6)
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let caretOn = focused && Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                HStack(spacing: 2) {
                    Text(text.isEmpty ? placeholder : text)
                        .opacity(text.isEmpty ? 0.4 : 1)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if focused {
                        Rectangle().frame(width: 3, height: 34).opacity(caretOn ? 1 : 0)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 30, weight: .medium))
                .padding(.horizontal, 24)
                .frame(height: 72)
                .foregroundStyle(focused ? .black : .white)
                .background(focused ? .white : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
    }
}
