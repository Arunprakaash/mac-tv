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
            if case .player = tv.mode, let web = tv.webView {
                WebViewHost(webView: web).id(ObjectIdentifier(web))
            } else {
                Wallpaper().ignoresSafeArea()
                TVCanvas { HomeView(tv: tv) }
                    .ignoresSafeArea()
                if tv.settings != nil {
                    TVCanvas { SettingsSheet(tv: tv) }
                        .ignoresSafeArea()
                        .background(.ultraThinMaterial.opacity(0.9))
                        .transition(Motion.sheet(reduceMotion: reduceMotion))
                }
                if tv.pairing {
                    TVCanvas { PairSheet(links: tv.remoteLinks, code: tv.remoteToken) { tv.pairing = false } }
                        .ignoresSafeArea()
                        .background(.ultraThinMaterial.opacity(0.9))
                        .transition(Motion.sheet(reduceMotion: reduceMotion))
                }
                if tv.adder != nil {
                    TVCanvas { AddAppSheet(tv: tv) }
                        .ignoresSafeArea()
                        .background(.ultraThinMaterial.opacity(0.9))
                        .transition(Motion.sheet(reduceMotion: reduceMotion))
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

            if let toast = tv.toast {
                VStack {
                    GlassGroup {
                        Text(toast)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22).padding(.vertical, 12)
                            .tvGlass(in: Capsule())
                            .tvGlassTransition()
                    }
                    .padding(.top, 36)
                    Spacer()
                }
                .transition(reduceMotion ? .opacity : .offset(y: -24).combined(with: .opacity))
            }
        }
        .environment(\.colorScheme, .dark)
        .background(Color.black.ignoresSafeArea())
        .animation(Motion.appear, value: tv.toast)
        .animation(Motion.appear, value: tv.pairing)
        .animation(Motion.appear, value: tv.settings != nil)
        .animation(Motion.appear, value: tv.adder != nil)
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
            if Aerials.films.isEmpty {
                DriftingColor()
            } else {
                AerialPlayer(films: Aerials.films)
            }
            // Keeps the clock legible over bright skies.
            LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .center)

            TimelineView(.everyMinute) { context in
                VStack(spacing: 0) {
                    Text(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.system(size: 34, weight: .semibold))
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
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }
}

/// Apple's aerial screen-saver films, if the Mac has downloaded any.
enum Aerials {
    static let films: [URL] = {
        let folder = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "mov" }.shuffled()
    }()
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

/// The fallback: soft colour drifting slowly across the screen.
struct DriftingColor: View {
    @Environment(\.canvasSize) private var canvas
    private static let palette = ["#1E3A8A", "#6D28D9", "#0E7490", "#9D174D", "#155E75", "#4338CA"]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Color(hex: "#05060A")
                ForEach(Array(Self.palette.enumerated()), id: \.offset) { index, hex in
                    // Each glow wanders on its own slow orbit.
                    let phase = t / (38 + Double(index) * 7) + Double(index) * 1.7
                    RadialGradient(colors: [Color(hex: hex).opacity(0.55), .clear],
                                   center: UnitPoint(x: 0.5 + 0.42 * cos(phase), y: 0.5 + 0.38 * sin(phase * 1.3)),
                                   startRadius: 0, endRadius: canvas.width * 0.45)
                        .blendMode(.screen)
                }
            }
        }
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
        if case .shelf = tv.focus { return true }
        return false
    }

    var body: some View {
        let layout = Layout(canvas: canvas)
        ZStack(alignment: .topLeading) {
            TopShelf(tv: tv, expanded: shelfFocused)
                .opacity(tv.inGrid ? 0 : 1)

            AppGrid(tv: tv)
                // An expanded banner takes the whole screen; the dock slides away.
                .offset(y: tv.inGrid ? -layout.gridShift : (shelfFocused ? 360 : 0))
                .opacity(shelfFocused ? 0 : 1)

            if !tv.inGrid && !shelfFocused && tv.shelfCount > 0 {
                Image(systemName: "chevron.compact.up")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .position(x: canvas.width / 2, y: layout.dockFrame.minY - 30)
                    .transition(.opacity)
            }

            GlassGroup { HStack(spacing: 14) {
                // While the Mac can't sleep with its lid closed, say so where it's always seen.
                if tv.lidSleepOff {
                    Label("Lid sleep off", systemImage: "moon.zzz")
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.horizontal, 20)
                        .frame(height: 50)
                        .tvGlass(in: Capsule())
                        .tvGlassID("lid", in: pills)
                }
                if let controller = tv.controller {
                    ControllerHints(info: controller).tvGlassID("controller", in: pills)
                }
                ClockPill().tvGlassID("clock", in: pills)
            } }
                .animation(Motion.appear, value: tv.lidSleepOff)
                .animation(Motion.appear, value: tv.controller)
                // The volume indicator and the controller banner take this corner while they show.
                .opacity(tv.volume == nil && tv.controllerNotice == nil ? 1 : 0)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 96)
                .padding(.top, 56)
                .opacity(tv.inGrid ? 0 : 1)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
        .foregroundStyle(.white)
        .animation(Motion.navigate, value: tv.inGrid)
        .animation(Motion.navigate, value: shelfFocused)
        .animation(Motion.appear, value: tv.shelfAppIndex)
    }
}

struct ClockPill: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(context.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 24, weight: .semibold))
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
            GlassDock()
                .frame(width: layout.dockFrame.width, height: layout.dockFrame.height)
                .offset(x: layout.dockFrame.minX, y: layout.dockFrame.minY)
                .opacity(tv.inGrid ? 0 : 1)

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
    var body: some View {
        Color.clear
            .tvGlass(in: RoundedRectangle(cornerRadius: 48, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 16)
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
            .overlay(alignment: .bottom) {
                Text(service.name)
                    .font(.system(size: 24, weight: .semibold))
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
                Text(service.name).font(.system(size: 30, weight: .heavy))
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
    @Environment(\.canvasSize) private var canvas
    let service: Service
    let expanded: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Artwork(accent: service.accent, deep: service.deep)
                .frame(width: canvas.width, height: canvas.height)
                .clipped()
            // Legibility: a soft top-left wash for the name, a bottom wash for the dock or button.
            LinearGradient(stops: [.init(color: .black.opacity(expanded ? 0.8 : 0.55), location: 0),
                                   .init(color: .black.opacity(expanded ? 0.4 : 0.15), location: 0.4),
                                   .init(color: .clear, location: 0.65)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.5),
                                   .init(color: .black.opacity(0.75), location: 1)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 18) {
                // SF Pro at standard width, in the app's own capitalization, as Apple TV sets titles.
                Text(service.name)
                    .font(.system(size: 92, weight: .bold))
                    .tracking(-1.5)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                if expanded {
                    ShelfButton(title: "Open \(service.name)", systemImage: "play.fill", focused: tv.focus == .shelf(0)) {
                        tv.setFocus(.shelf(0)); tv.activateShelf(0)
                    }
                    .padding(.top, 20)
                    .transition(.opacity.combined(with: .offset(y: 16)))
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 24, weight: .bold))
            .padding(.horizontal, 34)
            .frame(height: 66)
            .foregroundStyle(focused ? .black : .white)
            .tvGlass(in: Capsule(), interactive: true, tint: focused ? .white : nil)
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
    let links: [RemoteLink]
    let code: String
    let done: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 56) {
            HStack(spacing: 28) {
                if links.isEmpty {
                    RoundedRectangle(cornerRadius: 28).fill(.white.opacity(0.1))
                        .frame(width: 300, height: 300)
                        .overlay(Text("Connect to Wi-Fi\nor Tailscale").multilineTextAlignment(.center)
                            .font(.system(size: 22, weight: .semibold)).opacity(0.7))
                }
                ForEach(links) { link in
                    VStack(spacing: 14) {
                        if let qr = link.qr {
                            Image(nsImage: qr).interpolation(.none).resizable()
                                .frame(width: 260, height: 260)
                                .padding(20)
                                .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        }
                        Text(link.label).font(.system(size: 22, weight: .semibold)).opacity(0.8)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 18) {
                Text("MAC TV REMOTE").font(.system(size: 20, weight: .bold)).tracking(2.4).opacity(0.6)
                Text("Use your phone as a remote")
                    .font(.system(size: 46, weight: .heavy)).tracking(-1)
                Text("Scan with your phone's camera, then add the page to your home screen. Use the Tailscale code when you're away from home or your Wi-Fi keeps devices apart.")
                    .font(.system(size: 23)).foregroundStyle(.white.opacity(0.75))
                    .lineSpacing(4)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(links) { link in Text("\(link.label): \(link.address)") }
                    Text("Pairing code \(code)")
                }
                .font(.system(size: 20, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
                ShelfButton(title: "Done", focused: true, action: done)
                    .padding(.top, 8)
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
        .padding(56)
        .tvGlass(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
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
    /// Focus moving between tiles, rows and buttons: quick, with a hint of bounce.
    static let focus = Animation.snappy(duration: 0.28, extraBounce: 0.04)
    /// Scrolling between the Top Shelf, dock and grid.
    static let navigate = Animation.smooth(duration: 0.5)
    /// Sheets, toasts and pills arriving and leaving.
    static let appear = Animation.smooth(duration: 0.35)
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
    @ViewBuilder
    func tvGlass<S: InsettableShape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(tint ?? .clear, in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.18)))
        }
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

/// Groups nearby glass so it renders in one pass and can blend and morph together
/// (GlassEffectContainer); a plain stack before macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 14
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
                Text("Volume is set on the TV").font(.system(size: 22, weight: .semibold))
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
            Text("Add an app").font(.system(size: 52, weight: .heavy)).tracking(-1)

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
                ShelfButton(title: "Add to Home Screen", systemImage: "plus", focused: a.row == 3) {
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
                .font(.system(size: 22, weight: a.message == nil ? .regular : .semibold))
                .foregroundStyle(a.failed ? Color(hex: "#FF8A80") : .white.opacity(a.message == nil ? 0.55 : 0.9))
        }
        .padding(56)
        .frame(width: 1100, alignment: .leading)
        .tvGlass(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
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
            .font(.system(size: 24, weight: .bold))
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
                    Text(game.name).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if added { Text("On TV").font(.system(size: 18, weight: .bold)).opacity(0.6) }
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
                    .font(.system(size: 22)).opacity(0.6).padding(.top, 6)
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
                Text("No apps match.").font(.system(size: 24)).opacity(0.6)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            }
            ForEach(Array(matches.enumerated().dropFirst(start).prefix(window)), id: \.element.bundleID) { index, app in
                let focused = a.row == 2 && a.selected == index
                let added = tv.isOnHomeScreen(app)
                HStack(spacing: 18) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable().frame(width: 44, height: 44)
                    Text(app.name).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if added {
                        Text("On TV").font(.system(size: 18, weight: .bold)).opacity(0.6)
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
            Text(label).font(.system(size: 20, weight: .bold)).tracking(1).textCase(.uppercase).opacity(0.6)
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
