import SwiftUI

// The home screen follows Apple TV (tvOS 26): the focused app's Top Shelf fills the
// screen behind a frosted glass dock of 5:3 icons. Scroll layout peeks the next row and
// scrolls the grid; Pages layout keeps the dock and swaps six tiles at a time. Moving up
// expands the Top Shelf. App changes cross-fade the backdrop. Everything is laid out on a
// canvas 1920 points wide (or 1080 tall, whichever fits), stretched along the other axis
// so it fills any window shape edge to edge.

private struct Layout {
    static let tile = CGSize(width: 250, height: 150)
    static let tileSpacing: CGFloat = 28
    static let dockPadding: CGFloat = 44
    static let rowGap: CGFloat = 80
    /// Dock top inset from the canvas bottom; Top Shelf marks center above this band.
    static let dockClearance: CGFloat = 320

    let canvas: CGSize

    /// The dock sits a fixed distance from the bottom; extra height goes to the Top Shelf.
    var dockFrame: CGRect {
        CGRect(x: (canvas.width - 1728) / 2, y: canvas.height - Self.dockClearance, width: 1728, height: 220)
    }
    /// How far everything moves up when focus goes below the dock.
    var gridShift: CGFloat { dockFrame.midY - Self.tile.height / 2 - 75 }
}

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
        let pages = tv.homeLayout == .pages
        // Scroll: dock at rest, then grid rises by row. Pages: dock stays put unless the shelf expands.
        let gridOffset: CGFloat = shelfFocused ? 420
            : (!pages && focusedRow > 0 ? -layout.gridShift - CGFloat(focusedRow - 1) * rowStride : 0)

        ZStack(alignment: .topLeading) {
            // Hero stays full-bleed behind the grid; only the dock/shelf expand path may nudge it.
            TopShelf(tv: tv, expanded: shelfFocused)
                .offset(y: !tv.inGrid && gridOffset < 0 ? gridOffset : 0)

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
                .modifier(ClearsCornerForNotices(notices: tv.notices, inGrid: tv.inGrid))
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
        .foregroundStyle(.white)
        .animation(Motion.navigate, value: focusedRow)
        .animation(Motion.navigate, value: shelfFocused)
        .animation(Motion.navigate, value: tv.homeLayout)
    }
}

/// Slides the status row up off the screen while the grid, the volume or a controller banner has
/// the corner. It slides rather than fading, so the glass never goes translucent.
private struct ClearsCornerForNotices: ViewModifier {
    @ObservedObject var notices: Notices
    let inGrid: Bool

    func body(content: Content) -> some View {
        content.offset(y: inGrid || notices.volume != nil || notices.controller != nil ? -200 : 0)
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

            if tv.homeLayout == .pages {
                // Offset by page index so down always sends the old row up and brings the next from below
                // (and the reverse going up) — unlike asymmetric transitions, which keep the insert-time edge.
                let page = min(tv.homePage, max(rows.count - 1, 0))
                let dockTop = top(ofRow: 0, in: layout)
                let stride = Layout.tile.height + Layout.rowGap
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    let delta = rowIndex - page
                    HStack(spacing: Layout.tileSpacing) {
                        ForEach(row) { item in
                            AppCell(tv: tv, item: item, showsLabel: false)
                        }
                    }
                    .offset(x: layout.dockFrame.minX + Layout.dockPadding,
                            y: dockTop + CGFloat(delta) * stride)
                    .opacity(delta == 0 ? 1 : 0)
                    .allowsHitTesting(delta == 0)
                    .zIndex(delta == 0 ? 1 : 0)
                }
            } else {
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
        .animation(Motion.navigate, value: tv.homePage)
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
        TiltingAppTile(pointer: tv.pointerTilt, service: service, focused: focused)
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

/// The pointer over the focused tile, apart from `TVController` so following it redraws only tiles.
final class PointerTilt: ObservableObject {
    @Published var value: CGSize = .zero
}

/// An app tile that leans towards the pointer while it has focus.
private struct TiltingAppTile: View {
    @ObservedObject var pointer: PointerTilt
    let service: Service
    let focused: Bool

    var body: some View {
        AppTile(service: service, focused: focused, tilt: focused ? pointer.value : .zero)
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
        if case .movies = service.kind {
            ZStack {
                LinearGradient(colors: [Color(hex: "#5E5CE6"), Color(hex: "#1F1A6B")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "film.stack")
                    .font(.system(size: 70, weight: .medium))
                    .foregroundStyle(.white)
            }
        } else if let tile = Icons.tile(for: service) {
            // Built-ins, Mac apps, Add App and Settings: TileArt 5:3 (SF Symbol marks for system tiles).
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
