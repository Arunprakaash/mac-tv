import SwiftUI

struct AddAppSheet: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas
    @Namespace private var focusSpace
    /// Bumps as suggested logos arrive from the network / disk cache.
    @State private var suggestionIconTick = 0

    var body: some View {
        let a = tv.adder ?? AppAdder()
        VStack(alignment: .leading, spacing: 26) {
            Text("Add an app").font(.tv(.title3, emphasized: true))

            HStack(spacing: 6) {
                tab("Website", .website, a)
                tab("Suggested", .suggested, a)
                tab("Mac app", .macApp, a)
                if tv.adderTabs.contains(.steam) { tab("Steam", .steam, a) }
            }
            .padding(6)
            .background(.white.opacity(a.row == 0 ? 0.22 : 0.08), in: Capsule())
            .scaleEffect(a.row == 0 ? 1.03 : 1)
            .animation(Motion.focus, value: a.tab)
            .animation(Motion.focus, value: a.row)

            if a.tab == .website {
                AdderField(label: "Website", text: a.address, placeholder: "e.g. crunchyroll.com", focused: a.row == 1) { set(row: 1) }
                AdderField(label: "Name (optional)", text: a.name, placeholder: "Taken from the website", focused: a.row == 2) { set(row: 2) }
                ShelfButton(title: "Add to Home Screen", systemImage: "plus", focused: a.row == 3, glass: false) {
                    set(row: 3)
                    tv.submitAdder()
                }
            } else if a.tab == .suggested {
                suggestedList(a)
            } else if a.tab == .macApp {
                AdderField(label: "Search apps on this Mac", text: a.query, placeholder: "Type to filter", focused: a.row == 1) { set(row: 1) }
                macList(a)
            } else {
                steamList(a)
            }

            Text(a.message ?? footer(for: a))
                .font(.tv(.caption2, emphasized: a.message != nil))
                .foregroundStyle(a.failed ? Color(hex: "#FF8A80") : .white.opacity(a.message == nil ? 0.55 : 0.9))
            InputHintsBar(tv: tv, set: adderHints(a))
        }
        .padding(56)
        .frame(width: 1100, alignment: .leading)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .task(id: "\(a.tab)-\(a.moreServicesExpanded)") {
            guard a.tab == .suggested else { return }
            let services = tv.adderSuggestions.map(\.service)
            await SuggestionIcons.prefetch(services) {
                suggestionIconTick &+= 1
            }
        }
    }

    private func set(row: Int) {
        tv.adder?.row = row
    }

    private func footer(for a: AppAdder) -> String {
        switch a.tab {
        case .suggested:
            "Select adds or removes."
        case .steam:
            "Select adds or removes. Games open through Steam; Mac TV returns when you quit."
        case .macApp:
            "Select adds or removes. Type to filter."
        case .website:
            "Type with the keyboard or the remote's typing box."
        }
    }

    /// Select verb follows the focused control (add/remove, show/hide, or plain Select).
    private func adderHints(_ a: AppAdder) -> HintSet {
        .custom([.moveVertical("Choose"), .select(adderSelectVerb(a)), .back("Close")])
    }

    private func adderSelectVerb(_ a: AppAdder) -> String {
        switch a.tab {
        case .website:
            return a.row == 3 ? "Add" : "Select"
        case .suggested:
            guard a.row == 1 else { return "Select" }
            let rows = tv.adderSuggestionRows
            guard rows.indices.contains(a.selected) else { return "Select" }
            switch rows[a.selected] {
            case .header:
                return "Select"
            case .moreServices:
                return a.moreServicesExpanded ? "Hide" : "Show"
            case .item(let pick):
                return tv.isOnHomeScreen(pick.service) ? "Remove from Home Screen" : "Add to Home Screen"
            }
        case .steam:
            guard a.row == 1 else { return "Select" }
            let games = tv.adderSteamGames
            guard games.indices.contains(a.selected) else { return "Select" }
            return tv.isOnHomeScreen(games[a.selected]) ? "Remove from Home Screen" : "Add to Home Screen"
        case .macApp:
            guard a.row == 2 else { return "Select" }
            let matches = tv.adderMatches
            guard matches.indices.contains(a.selected) else { return "Select" }
            return tv.isOnHomeScreen(matches[a.selected]) ? "Remove from Home Screen" : "Add to Home Screen"
        }
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
                tv.adder?.moreServicesExpanded = false
                tv.adder?.selected = tab == .suggested ? tv.firstFocusableSuggestionRow() : 0
            }
    }

    private static let listRow: CGFloat = 60
    private static let listGap: CGFloat = 6
    fileprivate static var listStride: CGFloat { listRow + listGap }
    private static let iconSlot = CGSize(width: 44, height: 44)

    /// Dim label/badge for apps still addable; On TV stays full white. Icons always full opacity.
    private func labelOpacity(dimmed: Bool, onPlate: Bool) -> Double {
        dimmed && !onPlate ? 0.55 : 1
    }

    private func listRowStyle<Content: View>(
        onPlate: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 18)
            .frame(height: Self.listRow)
            .background {
                if !onPlate {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.06))
                }
            }
    }

    /// Builds row trees once per discrete selection change; `AdderScrollingList` interpolates `selected` alone.
    private func scrollingList<Rows: View>(
        selected: Int,
        count: Int,
        window: Int,
        plateVisible: Bool,
        animateSelection: Bool,
        @ViewBuilder rows: @escaping (_ onPlate: Bool) -> Rows
    ) -> some View {
        let viewport = CGFloat(min(window, max(count, 1))) * Self.listStride - Self.listGap
        return AdderScrollingList(
            selected: CGFloat(selected),
            count: count,
            window: window,
            plateVisible: plateVisible,
            viewportHeight: viewport,
            whiteRows: rows(false),
            blackRows: rows(true)
        )
        .animation(animateSelection ? Motion.focus : nil, value: selected)
    }

    /// Included / Suggested for you / More services. Select toggles On TV or expands More.
    @ViewBuilder private func suggestedList(_ a: AppAdder) -> some View {
        // One catalogue pass per body (not per animation frame).
        let rows = tv.adderSuggestionRows
        let window = 10
        let _ = suggestionIconTick
        if rows.isEmpty {
            Text("Nothing to suggest right now.")
                .font(.tv(.caption1)).opacity(0.6)
                .frame(maxWidth: .infinity, minHeight: Self.listRow, alignment: .leading)
        } else {
            scrollingList(
                selected: a.selected,
                count: rows.count,
                window: window,
                plateVisible: a.row == 1,
                animateSelection: true
            ) { onPlate in
                VStack(alignment: .leading, spacing: Self.listGap) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        switch row {
                        case .header(let title):
                            Text(title)
                                .font(.tv(.caption2, emphasized: true))
                                .foregroundStyle(onPlate ? Color.clear : Color.white.opacity(0.45))
                                .padding(.horizontal, 8)
                                .frame(height: Self.listRow, alignment: .bottomLeading)
                        case .moreServices:
                            listRowStyle(onPlate: onPlate) {
                                suggestedMoreLabel(expanded: a.moreServicesExpanded, onPlate: onPlate)
                            }
                            .modifier(AdderRowTap(enabled: !onPlate) {
                                tv.adder?.row = 1
                                tv.adder?.selected = index
                                tv.addSelectedSuggestion()
                            })
                        case .item(let pick):
                            let service = pick.service
                            let onHome = tv.isOnHomeScreen(service)
                            let removed = tv.adderRemovedFlash(for: pick.id)
                            listRowStyle(onPlate: onPlate) {
                                suggestedItemLabel(
                                    service: service,
                                    onHome: onHome,
                                    removed: removed,
                                    onPlate: onPlate,
                                    dimmed: !onHome || removed
                                )
                            }
                            .modifier(AdderRowTap(enabled: !onPlate) {
                                tv.adder?.row = 1
                                tv.adder?.selected = index
                                tv.addSelectedSuggestion()
                            })
                        }
                    }
                }
            }
            .animation(nil, value: a.tab)
        }
    }

    private func suggestedMoreLabel(expanded: Bool, onPlate: Bool) -> some View {
        HStack(spacing: 18) {
            // Chevron is the control glyph — keep it on both layers (black on the plate).
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(onPlate ? Color.black : Color.white)
                .frame(width: Self.iconSlot.width, height: Self.iconSlot.height)
            Text("More services")
                .font(.tv(.body)).lineLimit(1)
                .foregroundStyle(onPlate ? Color.black : Color.white)
            Spacer()
            Text(expanded ? "Hide" : "Show")
                .font(.tv(.caption2, emphasized: true))
                .foregroundStyle(onPlate ? Color.black.opacity(0.55) : Color.white.opacity(0.55))
        }
    }

    private func suggestedItemLabel(service: Service, onHome: Bool, removed: Bool, onPlate: Bool, dimmed: Bool) -> some View {
        HStack(spacing: 18) {
            Group {
                if onPlate {
                    Color.clear
                } else {
                    suggestionIcon(service)
                }
            }
            .frame(width: Self.iconSlot.width, height: Self.iconSlot.height)
            Text(service.name).font(.tv(.body)).lineLimit(1)
                .foregroundStyle(onPlate ? Color.black : Color.white)
                .opacity(labelOpacity(dimmed: dimmed, onPlate: onPlate))
            Spacer()
            adderBadge(onHome: onHome, removed: removed, onPlate: onPlate)
                .opacity(labelOpacity(dimmed: dimmed, onPlate: onPlate))
        }
    }

    @ViewBuilder private func adderBadge(onHome: Bool, removed: Bool, onPlate: Bool) -> some View {
        let label = removed ? "Removed" : onHome ? "On TV" : nil
        if let label {
            Text(label)
                .font(.tv(.caption2, emphasized: true))
                .foregroundStyle(onPlate ? Color.black.opacity(0.55) : Color.white.opacity(0.55))
        }
    }

    private func suggestionIcon(_ service: Service) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let image = SuggestionIcons.image(for: service)
        return ZStack {
            shape.fill(Color(hex: service.accent))
            if let image {
                Image(nsImage: image).resizable().clipShape(shape)
            } else {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            }
        }
        .frame(width: Self.iconSlot.width, height: Self.iconSlot.height)
        .id(service.id)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func steamList(_ a: AppAdder) -> some View {
        // Snapshot once per body — not again for the black text layer's icon path.
        let games = tv.adderSteamGames
        scrollingList(
            selected: a.selected,
            count: games.count,
            window: 8,
            plateVisible: a.row == 1 && !games.isEmpty,
            animateSelection: true
        ) { onPlate in
            VStack(alignment: .leading, spacing: Self.listGap) {
                ForEach(Array(games.enumerated()), id: \.element.appID) { index, game in
                    let added = tv.isOnHomeScreen(game)
                    let removed = tv.adderRemovedFlash(for: game.appID)
                    listRowStyle(onPlate: onPlate) {
                        steamLabel(game: game, added: added, removed: removed, onPlate: onPlate, dimmed: !added || removed)
                    }
                    .modifier(AdderRowTap(enabled: !onPlate) {
                        tv.adder?.row = 1
                        tv.adder?.selected = index
                        tv.addSelectedSteamGame()
                    })
                }
                if games.count == 1 {
                    Text("No Steam games installed yet. Install some in Steam and they'll show up here.")
                        .font(.tv(.caption2)).opacity(onPlate ? 0 : 0.6).padding(.top, 6)
                }
            }
        }
        .animation(nil, value: a.tab)
    }

    private func steamLabel(game: SteamLibrary.Game, added: Bool, removed: Bool, onPlate: Bool, dimmed: Bool) -> some View {
        HStack(spacing: 18) {
            Group {
                if onPlate {
                    Color.clear
                } else if game == SteamLibrary.bigPicture, let url = SteamLibrary.appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                } else {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 24))
                }
            }
            .frame(width: Self.iconSlot.width, height: Self.iconSlot.height)
            Text(game.name).font(.tv(.body)).lineLimit(1)
                .foregroundStyle(onPlate ? Color.black : Color.white)
                .opacity(labelOpacity(dimmed: dimmed, onPlate: onPlate))
            Spacer()
            adderBadge(onHome: added, removed: removed, onPlate: onPlate)
                .opacity(labelOpacity(dimmed: dimmed, onPlate: onPlate))
        }
    }

    @ViewBuilder private func macList(_ a: AppAdder) -> some View {
        let matches = tv.adderMatches
        if matches.isEmpty {
            Text("No apps match.").font(.tv(.caption1)).opacity(0.6)
                .frame(maxWidth: .infinity, minHeight: Self.listRow, alignment: .leading)
        } else {
            scrollingList(
                selected: a.selected,
                count: matches.count,
                window: 8,
                plateVisible: a.row == 2,
                animateSelection: true
            ) { onPlate in
                VStack(spacing: Self.listGap) {
                    ForEach(Array(matches.enumerated()), id: \.element.bundleID) { index, app in
                        let added = tv.isOnHomeScreen(app)
                        let removed = tv.adderRemovedFlash(for: app.bundleID)
                        listRowStyle(onPlate: onPlate) {
                            macLabel(app: app, added: added, removed: removed, onPlate: onPlate, dimmed: !added || removed)
                        }
                        .modifier(AdderRowTap(enabled: !onPlate) {
                            tv.adder?.row = 2
                            tv.adder?.selected = index
                            tv.addSelectedMacApp()
                        })
                    }
                }
            }
            .animation(nil, value: a.query)
            .animation(nil, value: a.tab)
        }
    }

    private func macLabel(app: InstalledApps.App, added: Bool, removed: Bool, onPlate: Bool, dimmed: Bool) -> some View {
        HStack(spacing: 18) {
            Group {
                if onPlate {
                    Color.clear
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable()
                }
            }
            .frame(width: Self.iconSlot.width, height: Self.iconSlot.height)
            Text(app.name).font(.tv(.body)).lineLimit(1)
                .foregroundStyle(onPlate ? Color.black : Color.white)
                .opacity(labelOpacity(dimmed: dimmed, onPlate: onPlate))
            Spacer()
            adderBadge(onHome: added, removed: removed, onPlate: onPlate)
                .opacity(labelOpacity(dimmed: dimmed, onPlate: onPlate))
        }
    }
}

/// Tap only on the visible (white) row layer — black mask layer skips gestures.
private struct AdderRowTap: ViewModifier {
    var enabled: Bool
    var action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.contentShape(Rectangle()).onTapGesture(perform: action)
        } else {
            content.allowsHitTesting(false)
        }
    }
}

/// Plate + mask share one `Animatable` selection. Row trees are not rebuilt per spring frame.
private struct AdderScrollingList<Rows: View>: View, Animatable {
    /// Unsafe: Animatable reads/writes this off the main actor during interpolation.
    nonisolated(unsafe) var selected: CGFloat
    var count: Int
    var window: Int
    var plateVisible: Bool
    var viewportHeight: CGFloat
    var whiteRows: Rows
    var blackRows: Rows

    nonisolated var animatableData: CGFloat {
        get { selected }
        set { selected = newValue }
    }

    var body: some View {
        let stride = AddAppSheet.listStride
        let start = min(max(0, selected - CGFloat(window) / 2), CGFloat(max(0, count - window)))
        let plateY = (selected - start) * stride
        let plate = RoundedRectangle(cornerRadius: 16, style: .continuous)

        ZStack(alignment: .topLeading) {
            plate
                .fill(.white)
                .frame(height: 60)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: plateY)
                .opacity(plateVisible ? 1 : 0)
                .allowsHitTesting(false)

            whiteRows
                .offset(y: -start * stride)

            blackRows
                .offset(y: -start * stride)
                .mask(alignment: .topLeading) {
                    plate
                        .frame(height: 60)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .offset(y: plateY)
                }
                .opacity(plateVisible ? 1 : 0)
                .allowsHitTesting(false)
        }
        .frame(height: viewportHeight, alignment: .top)
        .clipped()
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
