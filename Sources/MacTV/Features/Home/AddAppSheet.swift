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
            InputHintsBar(tv: tv, set: .form)
        }
        .padding(56)
        .frame(width: 1100, alignment: .leading)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.focus, value: a)
        .task(id: "\(a.tab)-\(a.moreServicesExpanded)") {
            guard a.tab == .suggested else { return }
            let services = tv.adderSuggestions.map(\.service)
            await SuggestionIcons.prefetch(services) {
                suggestionIconTick += 1
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

    /// Included / Suggested for you / More services. Select toggles On TV or expands More.
    @ViewBuilder private func suggestedList(_ a: AppAdder) -> some View {
        let rows = tv.adderSuggestionRows
        let window = 10
        let start = min(max(0, a.selected - window / 2), max(0, rows.count - window))
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                Text("Nothing to suggest right now.")
                    .font(.tv(.caption1)).opacity(0.6)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            }
            ForEach(Array(rows.enumerated().dropFirst(start).prefix(window)), id: \.element.id) { index, row in
                switch row {
                case .header(let title):
                    Text(title)
                        .font(.tv(.caption2, emphasized: true))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, index == start ? 0 : 10)
                        .padding(.horizontal, 8)
                case .moreServices:
                    let focused = a.row == 1 && a.selected == index
                    HStack(spacing: 18) {
                        Image(systemName: a.moreServicesExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                        Text("More services")
                            .font(.tv(.body)).lineLimit(1)
                        Spacer()
                        Text(a.moreServicesExpanded ? "Hide" : "Show")
                            .font(.tv(.caption2, emphasized: true))
                            .opacity(focused ? 0.55 : 0.6)
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        tv.adder?.row = 1
                        tv.adder?.selected = index
                        tv.addSelectedSuggestion()
                    }
                case .item(let pick):
                    let focused = a.row == 1 && a.selected == index
                    let service = pick.service
                    let onHome = tv.isOnHomeScreen(service)
                    let removed = tv.adderRemovedFlash(for: pick.id)
                    HStack(spacing: 18) {
                        suggestionIcon(service)
                        Text(service.name).font(.tv(.body)).lineLimit(1)
                        Spacer()
                        adderBadge(onHome: onHome, removed: removed, focused: focused)
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
                    .opacity(onHome && !focused && !removed ? 0.55 : 1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        tv.adder?.row = 1
                        tv.adder?.selected = index
                        tv.addSelectedSuggestion()
                    }
                }
            }
        }
    }

    @ViewBuilder private func adderBadge(onHome: Bool, removed: Bool, focused: Bool) -> some View {
        let label = removed ? "Removed" : onHome ? "On TV" : nil
        if let label {
            Text(label)
                .font(.tv(.caption2, emphasized: true))
                .opacity(focused ? 0.55 : 0.6)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.55), value: label)
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
        .frame(width: 44, height: 44)
        .id("\(service.id)-\(suggestionIconTick)")
        // Row focus tints labels; keep the glyph readable on light brand colours (DAZN yellow).
        .environment(\.colorScheme, .dark)
    }

    /// Steam Big Picture and the installed games, eight rows at a time.
    @ViewBuilder private func steamList(_ a: AppAdder) -> some View {
        let games = tv.adderSteamGames
        let window = 8
        let start = min(max(0, a.selected - window / 2), max(0, games.count - window))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(games.enumerated().dropFirst(start).prefix(window)), id: \.element.appID) { index, game in
                let focused = a.row == 1 && a.selected == index
                let added = tv.isOnHomeScreen(game)
                let removed = tv.adderRemovedFlash(for: game.appID)
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
                    adderBadge(onHome: added, removed: removed, focused: focused)
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
                .opacity(added && !focused && !removed ? 0.55 : 1)
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
                let removed = tv.adderRemovedFlash(for: app.bundleID)
                HStack(spacing: 18) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable().frame(width: 44, height: 44)
                    Text(app.name).font(.tv(.body)).lineLimit(1)
                    Spacer()
                    adderBadge(onHome: added, removed: removed, focused: focused)
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
                .opacity(added && !focused && !removed ? 0.55 : 1)
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
