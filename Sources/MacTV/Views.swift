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

    var body: some View {
        ZStack {
            if case .player = tv.mode, let web = tv.webView {
                WebViewHost(webView: web).id(ObjectIdentifier(web))
            } else {
                Wallpaper().ignoresSafeArea()
                TVCanvas { HomeView(tv: tv) }
                    .ignoresSafeArea()
                if tv.pairing {
                    TVCanvas { PairSheet(links: tv.remoteLinks, code: tv.remoteToken) { tv.pairing = false } }
                        .ignoresSafeArea()
                        .background(.ultraThinMaterial.opacity(0.9))
                        .transition(.opacity)
                }
                if tv.adder != nil {
                    TVCanvas { AddAppSheet(tv: tv) }
                        .ignoresSafeArea()
                        .background(.ultraThinMaterial.opacity(0.9))
                        .transition(.opacity)
                }
                if tv.screensaver {
                    TVCanvas { Screensaver() }
                        .ignoresSafeArea()
                        .transition(.opacity.animation(.easeInOut(duration: 1.2)))
                }
            }

            if let toast = tv.toast {
                VStack {
                    Text(toast)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 36)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .environment(\.colorScheme, .dark)
        .background(Color.black.ignoresSafeArea())
        .animation(.easeOut(duration: 0.25), value: tv.toast)
        .animation(.easeOut(duration: 0.25), value: tv.pairing)
        .animation(.easeOut(duration: 0.25), value: tv.adder != nil)
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
                        .font(.system(size: 230, weight: .bold, design: .rounded))
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

    private var shelfFocused: Bool {
        if case .shelf = tv.focus { return true }
        return false
    }

    var body: some View {
        let showcase = tv.shelfService.isWeb && tv.shelfService.shelf == .showcase
        let layout = Layout(canvas: canvas)
        ZStack(alignment: .topLeading) {
            TopShelf(tv: tv, expanded: shelfFocused)
                .opacity(tv.inGrid ? 0 : 1)

            AppGrid(tv: tv)
                // An expanded showcase takes the whole screen; the dock slides away.
                .offset(y: tv.inGrid ? -layout.gridShift : (shelfFocused && showcase ? 360 : 0))
                .opacity(shelfFocused && showcase ? 0 : 1)

            if !tv.inGrid && !shelfFocused && tv.shelfCount > 0 {
                Image(systemName: "chevron.compact.up")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .position(x: canvas.width / 2, y: layout.dockFrame.minY - 30)
                    .transition(.opacity)
            }

            ClockPill()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 96)
                .padding(.top, 56)
                .opacity(tv.inGrid ? 0 : 1)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
        .foregroundStyle(.white)
        .animation(.spring(response: 0.55, dampingFraction: 0.88), value: tv.inGrid)
        .animation(.spring(response: 0.5, dampingFraction: 0.88), value: shelfFocused)
        .animation(.easeInOut(duration: 0.35), value: tv.shelfAppIndex)
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
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
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
        let shape = RoundedRectangle(cornerRadius: 48, style: .continuous)
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(.white.opacity(0.05)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.05)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1.2))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
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
                    .animation(.easeOut(duration: 0.2), value: focused)
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

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        artwork
            .frame(width: Layout.tile.width, height: Layout.tile.height)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.06)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .opacity(focused ? 1 : 0)
            }
            .rotation3DEffect(.degrees(-tilt.height * 10), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tilt.width * 12), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .scaleEffect(focused ? 1.14 : 1)
            .offset(y: focused ? -10 : 0)
            // Resting icons sit flat on the glass; only the focused one casts a shadow.
            .shadow(color: .black.opacity(focused ? 0.65 : 0), radius: focused ? 26 : 0, y: focused ? 26 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: focused)
            .animation(.easeOut(duration: 0.12), value: tilt)
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
            if service.isWeb {
                switch service.shelf {
                case .showcase:
                    ShowcaseShelf(tv: tv, service: service, item: tv.shelfItems.first, expanded: expanded)
                case .row(let label):
                    RowShelf(tv: tv, service: service, label: label, items: tv.shelfItems)
                }
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .id(service.id)
        .transition(.opacity)
    }

    static func focusIndex(_ tv: TVController) -> Int? {
        if case .shelf(let index) = tv.focus { return index }
        return nil
    }
}

/// Full-screen artwork of the last thing watched. With the dock focused, the title sits
/// top-left over the art; moving up expands it with details and Resume.
struct ShowcaseShelf: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas
    let service: Service
    let item: WatchItem?
    let expanded: Bool

    var body: some View {
        let focusIndex = TopShelf.focusIndex(tv)
        ZStack(alignment: .topLeading) {
            Artwork(accent: service.accent, deep: service.deep)
                .frame(width: canvas.width, height: canvas.height)
                .clipped()
            // Legibility: a soft top-left wash for the title, a bottom wash for the dock or details.
            LinearGradient(stops: [.init(color: .black.opacity(expanded ? 0.8 : 0.55), location: 0),
                                   .init(color: .black.opacity(expanded ? 0.4 : 0.15), location: 0.4),
                                   .init(color: .clear, location: 0.65)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.5),
                                   .init(color: .black.opacity(0.75), location: 1)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 18) {
                Text(item == nil ? service.name.uppercased() : "CONTINUE WATCHING ON \(service.name.uppercased())")
                    .font(.system(size: 20, weight: .bold)).tracking(2.4)
                    .foregroundStyle(.white.opacity(0.8))
                Text(item.map { $0.title ?? "Pick up where you left off" } ?? "Nothing watched yet")
                    .font(.system(size: 112, weight: .black).width(.compressed))
                    .textCase(.uppercase)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                if expanded {
                    Text(item.map { "Watched \($0.date.formatted(.relative(presentation: .named)))" }
                         ?? "What you watch on \(service.name) shows up here.")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                    HStack(spacing: 18) {
                        if item != nil {
                            ShelfButton(title: "Resume", systemImage: "play.fill", focused: focusIndex == 0) {
                                tv.setFocus(.shelf(0)); tv.activateShelf(0)
                            }
                            ShelfButton(title: "Open \(service.name)", focused: focusIndex == 1) {
                                tv.setFocus(.shelf(1)); tv.activateShelf(1)
                            }
                        } else {
                            ShelfButton(title: "Open \(service.name)", systemImage: "play.fill", focused: focusIndex == 0) {
                                tv.setFocus(.shelf(0)); tv.activateShelf(0)
                            }
                        }
                    }
                    .padding(.top, 20)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
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
            .background {
                if focused {
                    Capsule().fill(.white)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22)))
                }
            }
            .scaleEffect(focused ? 1.08 : 1)
            .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 20, y: 14)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focused)
        }
        .buttonStyle(.plain)
    }
}

/// A labelled row of 16:9 cards above the dock.
struct RowShelf: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas
    let service: Service
    let label: String
    let items: [WatchItem]

    var body: some View {
        let focusIndex = TopShelf.focusIndex(tv)
        ZStack(alignment: .topLeading) {
            // The app's colours tint the whole screen.
            Artwork(accent: service.accent, deep: service.deep)
                .frame(width: canvas.width, height: canvas.height)
                .blur(radius: 60)
                .opacity(0.55)
                .clipped()
            LinearGradient(colors: [.clear, Color(hex: "#0A0B0E").opacity(0.8)], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 24) {
                Text(label).font(.system(size: 28, weight: .bold))
                HStack(spacing: 40) {
                    if items.isEmpty {
                        ShelfCard(service: service, item: nil, focused: focusIndex == 0) {
                            tv.setFocus(.shelf(0)); tv.activateShelf(0)
                        }
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ShelfCard(service: service, item: item, focused: focusIndex == index) {
                                tv.setFocus(.shelf(index)); tv.activateShelf(index)
                            }
                        }
                    }
                }
                .offset(x: -CGFloat(max(0, (focusIndex ?? 0) - 2)) * 640)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: focusIndex)
            }
            .padding(.leading, 96)
            .padding(.top, 150)
        }
    }
}

struct ShelfCard: View {
    let service: Service
    let item: WatchItem?
    let focused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                Artwork(accent: service.accent, deep: service.deep)
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 12) {
                    if let item {
                        Text(item.title ?? "Pick up where you left off")
                            .font(.system(size: 30, weight: .heavy))
                            .lineLimit(1)
                        if let progress = item.progress {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.28))
                                    Capsule().fill(.white).frame(width: geo.size.width * min(max(progress, 0.03), 1))
                                }
                            }
                            .frame(height: 5)
                        }
                    } else {
                        Text("Open \(service.name)").font(.system(size: 30, weight: .heavy))
                        Text("What you play shows up here.")
                            .font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(26)
            }
            .frame(width: 600, height: 338)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(focused ? 0.4 : 0), lineWidth: 1.2))
            .scaleEffect(focused ? 1.06 : 1)
            .shadow(color: .black.opacity(focused ? 0.6 : 0.35), radius: focused ? 28 : 12, y: focused ? 24 : 8)
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: focused)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
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
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                ShelfButton(title: "Done", focused: true, action: done)
                    .padding(.top, 8)
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
        .padding(56)
        .background(Color(hex: "#282A32").opacity(0.85), in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 44, style: .continuous).strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.5), radius: 50, y: 30)
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
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

    var body: some View {
        let a = tv.adder ?? AppAdder()
        VStack(alignment: .leading, spacing: 26) {
            Text("Add an app").font(.system(size: 52, weight: .heavy)).tracking(-1)

            HStack(spacing: 6) {
                tab("Website", .website, a)
                tab("Mac app", .macApp, a)
            }
            .padding(6)
            .background(.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(a.row == 0 ? 0.9 : 0), lineWidth: 3))

            if a.tab == .website {
                AdderField(label: "Website", text: a.address, placeholder: "e.g. crunchyroll.com", focused: a.row == 1) { set(row: 1) }
                AdderField(label: "Name (optional)", text: a.name, placeholder: "Taken from the website", focused: a.row == 2) { set(row: 2) }
                ShelfButton(title: "Add to Home Screen", systemImage: "plus", focused: a.row == 3) {
                    set(row: 3)
                    tv.submitAdder()
                }
            } else {
                AdderField(label: "Search apps on this Mac", text: a.query, placeholder: "Type to filter", focused: a.row == 1) { set(row: 1) }
                macList(a)
            }

            Text(a.message ?? "Type with the keyboard or the remote's typing box. Esc or Back closes.")
                .font(.system(size: 22, weight: a.message == nil ? .regular : .semibold))
                .foregroundStyle(a.failed ? Color(hex: "#FF8A80") : .white.opacity(a.message == nil ? 0.55 : 0.9))
        }
        .padding(56)
        .frame(width: 1100, alignment: .leading)
        .background(Color(hex: "#282A32").opacity(0.9), in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 44, style: .continuous).strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.5), radius: 50, y: 30)
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(.easeOut(duration: 0.18), value: a)
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
            .background(on ? Color.white : Color.clear, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                tv.adder?.tab = tab
                tv.adder?.row = 1
                tv.adder?.selected = 0
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
                .background(focused ? Color.white : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                .background(.white.opacity(focused ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(focused ? 0.9 : 0.12), lineWidth: focused ? 3 : 1))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
    }
}
