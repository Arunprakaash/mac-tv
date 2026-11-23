import AppKit

/// The TV's own add-app sheet: a website by address, suggested presets, a Mac app, or Steam.
/// It's driven entirely by the D-pad and typing, from the keyboard or the phone remote.
struct AppAdder: Equatable {
    enum Tab { case website, suggested, macApp, steam }

    var tab: Tab = .website
    /// Website: 0 tabs, 1 address, 2 name, 3 the add button. Suggested/Steam: 0 tabs, 1 the list.
    /// Mac app: 0 tabs, 1 search, 2 the list.
    var row = 1
    var address = ""
    var name = ""
    var query = ""
    /// The highlighted app in the Suggested, Mac app, or Steam list.
    var selected = 0
    var message: String?
    var failed = false
    /// Suggestion / Mac / Steam row id briefly showing "Removed" after a toggle-off.
    var removedFlashID: String?
    var removedFlashUntil: Date?
    /// Suggested tab: region-mismatched locals listed after *More services*.
    var moreServicesExpanded = false

    /// How long the ephemeral Removed badge stays before fading.
    static let removedFlashSeconds: TimeInterval = 4
}

/// A row in Add App › Suggested: a built-in (restore / toggle) or a streaming-site preset.
enum AdderSuggestion: Identifiable, Hashable {
    case restore(Service)
    case website(Service)

    var id: String {
        switch self {
        case .restore(let service): "restore-\(service.id)"
        case .website(let service): "web-\(service.id)"
        }
    }

    var service: Service {
        switch self {
        case .restore(let service), .website(let service): service
        }
    }
}

/// Flat Suggested list: section labels, toggle rows, and the More services control.
enum AdderSuggestionRow: Identifiable, Hashable {
    case header(String)
    case item(AdderSuggestion)
    case moreServices

    var id: String {
        switch self {
        case .header(let title): "header-\(title)"
        case .item(let suggestion): suggestion.id
        case .moreServices: "more-services"
        }
    }

    var isFocusable: Bool {
        switch self {
        case .header: false
        case .item, .moreServices: true
        }
    }
}

extension TVController {
    var adderMatches: [InstalledApps.App] { InstalledApps.matching(adder?.query ?? "") }

    /// Suggested sits between Website and Mac app; Steam only when installed.
    var adderTabs: [AppAdder.Tab] {
        var tabs: [AppAdder.Tab] = [.website, .suggested, .macApp]
        if SteamLibrary.isInstalled { tabs.append(.steam) }
        return tabs
    }

    /// Steam Big Picture, then every installed game.
    var adderSteamGames: [SteamLibrary.Game] { [SteamLibrary.bigPicture] + SteamLibrary.installedGames() }

    /// Actionable Suggested rows currently on screen (no section headers).
    var adderSuggestions: [AdderSuggestion] {
        adderSuggestionRows.compactMap {
            if case .item(let suggestion) = $0 { return suggestion }
            return nil
        }
    }

    /// Included (worldwide only) → Suggested for you (region locals) → More.
    /// One pass per catalogue; callers that navigate should reuse the array for the keypress.
    var adderSuggestionRows: [AdderSuggestionRow] {
        let region = Catalog.suggestionRegion
        var included: [AdderSuggestion] = []
        var forYou: [AdderSuggestion] = []
        var more: [AdderSuggestion] = []

        func place(_ suggestion: AdderSuggestion, regions: Set<String>?) {
            guard suggestion.service.isInstalled else { return }
            if regions == nil {
                included.append(suggestion)
            } else if Catalog.matchesSuggestionRegion(suggestion.service, region: region) {
                forYou.append(suggestion)
            } else {
                more.append(suggestion)
            }
        }

        for service in Catalog.services {
            guard service.kind != .addApp, service.kind != .settings else { continue }
            place(.restore(service), regions: service.regions)
        }
        for service in Catalog.websiteSuggestions {
            place(.website(service), regions: service.regions)
        }

        var rows: [AdderSuggestionRow] = []
        if !included.isEmpty {
            rows.append(.header("Included"))
            rows += included.map { .item($0) }
        }
        if !forYou.isEmpty {
            rows.append(.header("Suggested for you"))
            rows += forYou.map { .item($0) }
        }
        if !more.isEmpty {
            rows.append(.moreServices)
            if adder?.moreServicesExpanded == true {
                rows += more.map { .item($0) }
            }
        }
        return rows
    }

    /// First focusable Suggested row index (skips section headers).
    func firstFocusableSuggestionRow() -> Int {
        firstFocusableSuggestionRow(in: adderSuggestionRows)
    }

    private func firstFocusableSuggestionRow(in rows: [AdderSuggestionRow]) -> Int {
        rows.firstIndex(where: \.isFocusable) ?? 0
    }

    private func nextFocusableSuggestionRow(in rows: [AdderSuggestionRow], from index: Int, step: Int) -> Int? {
        var i = index + step
        while rows.indices.contains(i) {
            if rows[i].isFocusable { return i }
            i += step
        }
        return nil
    }

    private var adderLastRow: Int {
        switch adder?.tab {
        case .website: 3
        case .macApp: 2
        case .suggested, .steam, .none: 1
        }
    }

    func isOnHomeScreen(_ game: SteamLibrary.Game) -> Bool {
        services.contains { $0.kind == .steam(appID: game.appID) }
    }

    func isOnHomeScreen(_ app: InstalledApps.App) -> Bool {
        services.contains { $0.kind == .app(bundleID: app.bundleID) }
    }

    /// Built-in tile still visible, or a website already added with the same host.
    func isOnHomeScreen(_ service: Service) -> Bool {
        homeScreenMatch(for: service) != nil
    }

    /// True while the ephemeral Removed badge should show for this list row id.
    func adderRemovedFlash(for id: String) -> Bool {
        guard let a = adder, a.removedFlashID == id, let until = a.removedFlashUntil else { return false }
        return until > Date()
    }

    private func homeScreenMatch(for service: Service) -> Service? {
        if !library.isHidden(service.id),
           let exact = services.first(where: { $0.id == service.id }) {
            return exact
        }
        // User-added copy of a region-gated built-in (same host) still counts as On TV.
        guard case .web(let url) = service.kind, let host = Self.normalizedHost(url) else { return nil }
        return services.first {
            guard $0.id != service.id else { return false }
            guard case .web(let existing) = $0.kind else { return false }
            return Self.normalizedHost(existing) == host
        }
    }

    private func homeScreenMatch(bundleID: String) -> Service? {
        services.first { $0.kind == .app(bundleID: bundleID) }
    }

    private func homeScreenMatch(steamAppID: String) -> Service? {
        services.first { $0.kind == .steam(appID: steamAppID) }
    }

    private static func normalizedHost(_ url: URL) -> String? {
        url.host()?.lowercased().replacingOccurrences(of: "www.", with: "")
    }

    func handleAdder(_ command: RemoteCommand) {
        guard var a = adder else { return }
        let lastRow = adderLastRow
        let tabs = adderTabs
        let tabIndex = tabs.firstIndex(of: a.tab) ?? 0
        a.message = nil
        switch command {
        case .back:
            adder = nil
            return
        case .seek(let forward):
            // Shoulders always change the segment, even when focus is in a field below.
            let step = forward ? 1 : tabs.count - 1
            a.tab = tabs[(tabIndex + step) % tabs.count]
            a.moreServicesExpanded = false
            a.selected = a.tab == .suggested ? firstFocusableSuggestionRow() : 0
            a.row = min(a.row, Self.lastRow(for: a.tab))
        case .move(let direction) where direction == .left || direction == .right:
            if a.row == 0 {
                let step = direction == .right ? 1 : tabs.count - 1
                a.tab = tabs[(tabIndex + step) % tabs.count]
                a.moreServicesExpanded = false
                a.selected = a.tab == .suggested ? firstFocusableSuggestionRow() : 0
            }
        case .move(.up):
            let inList = (a.tab == .macApp && a.row == 2)
                || ((a.tab == .steam || a.tab == .suggested) && a.row == 1)
            if a.tab == .suggested, a.row == 1 {
                let rows = adderSuggestionRows
                if let next = nextFocusableSuggestionRow(in: rows, from: a.selected, step: -1) {
                    a.selected = next
                } else {
                    a.row = 0
                }
            } else if inList, a.selected > 0 {
                a.selected -= 1
            } else {
                a.row = max(0, a.row - 1)
            }
        case .move(.down):
            if a.tab == .macApp, a.row == 2 {
                a.selected = min(a.selected + 1, max(adderMatches.count - 1, 0))
            } else if a.tab == .steam, a.row == 1 {
                a.selected = min(a.selected + 1, max(adderSteamGames.count - 1, 0))
            } else if a.tab == .suggested, a.row == 1 {
                let rows = adderSuggestionRows
                if let next = nextFocusableSuggestionRow(in: rows, from: a.selected, step: 1) {
                    a.selected = next
                }
            } else if a.tab == .suggested, a.row == 0 {
                a.row = 1
                a.selected = firstFocusableSuggestionRow()
            } else if !(a.tab == .macApp && a.row == 1 && adderMatches.isEmpty) {
                a.row = min(lastRow, a.row + 1)
            }
        case .select:
            adder = a
            switch (a.tab, a.row) {
            case (_, 0):
                a.tab = tabs[(tabIndex + 1) % tabs.count]
                a.row = 1
                a.moreServicesExpanded = false
                a.selected = a.tab == .suggested ? firstFocusableSuggestionRow() : 0
            case (.website, 3): submitAdder(); return
            case (.macApp, 2): addSelectedMacApp(); return
            case (.steam, 1): addSelectedSteamGame(); return
            case (.suggested, 1): addSelectedSuggestion(); return
            default: a.row = min(lastRow, a.row + 1)
            }
        case .text(let text):
            let typed = text.replacingOccurrences(of: "\n", with: "")
            switch (a.tab, a.row) {
            case (.website, 2): a.name += typed
            case (.website, _): a.row = max(a.row, 1) == 3 ? 1 : max(a.row, 1); a.address += typed
            case (.macApp, _): a.row = 1; a.query += typed; a.selected = 0
            case (.steam, _), (.suggested, _): break
            }
            if text.hasSuffix("\n") { adder = a; handleAdder(.select); return }
        case .deleteBackward:
            switch (a.tab, a.row) {
            case (.website, 2): if !a.name.isEmpty { a.name.removeLast() }
            case (.website, _): if !a.address.isEmpty { a.address.removeLast() }
            case (.macApp, _): if !a.query.isEmpty { a.query.removeLast() }; a.selected = 0
            case (.steam, _), (.suggested, _): break
            }
        default:
            break
        }
        adder = a
    }

    private static func lastRow(for tab: AppAdder.Tab) -> Int {
        switch tab {
        case .website: 3
        case .macApp: 2
        case .suggested, .steam: 1
        }
    }

    func submitAdder() {
        guard var a = adder else { return }
        guard let app = addWebsite(name: a.name, address: a.address) else {
            a.message = a.address.isEmpty ? "Type a website address first." : "That doesn't look like a website address."
            a.failed = true
            adder = a
            return
        }
        finishSheet(focusID: app.id, message: "Added \(app.name). Finding its icon…")
    }

    func addSelectedMacApp() {
        guard let a = adder else { return }
        let matches = adderMatches
        guard matches.indices.contains(a.selected) else { return }
        let pick = matches[a.selected]
        if let home = homeScreenMatch(bundleID: pick.bundleID) {
            markRemovedFlash(pick.bundleID)
            removeApp(home.id)
            return
        }
        guard addMacApp(bundleID: pick.bundleID) != nil else { return }
        clearRemovedFlash(pick.bundleID)
    }

    func addSelectedSteamGame() {
        guard let a = adder else { return }
        let games = adderSteamGames
        guard games.indices.contains(a.selected) else { return }
        let pick = games[a.selected]
        if let home = homeScreenMatch(steamAppID: pick.appID) {
            markRemovedFlash(pick.appID)
            removeApp(home.id)
            return
        }
        guard addSteamGame(pick) != nil else { return }
        clearRemovedFlash(pick.appID)
    }

    func addSelectedSuggestion() {
        guard var a = adder else { return }
        let rows = adderSuggestionRows
        guard rows.indices.contains(a.selected) else { return }
        switch rows[a.selected] {
        case .header:
            return
        case .moreServices:
            a.moreServicesExpanded.toggle()
            // Rebuild once after expand so focus can land on the first revealed row.
            adder = a
            if a.moreServicesExpanded {
                let expanded = adderSuggestionRows
                if let next = nextFocusableSuggestionRow(in: expanded, from: a.selected, step: 1) {
                    a.selected = next
                    adder = a
                }
            }
            return
        case .item(let pick):
            if let home = homeScreenMatch(for: pick.service) {
                markRemovedFlash(pick.id)
                removeApp(home.id)
                return
            }
            switch pick {
            case .restore(let service):
                // Region-gated built-ins stay off Home when Locale ≠ regions; add as a website tile instead.
                if service.isAvailable {
                    library.setHidden(service.id, false)
                    reloadServices()
                    showToast("Added \(service.name)")
                } else if case .web(let url) = service.kind {
                    guard addWebsite(name: service.name, address: url.absoluteString) != nil else { return }
                } else {
                    return
                }
            case .website(let service):
                guard case .web(let url) = service.kind,
                      addWebsite(name: service.name, address: url.absoluteString) != nil else { return }
            }
            clearRemovedFlash(pick.id)
        }
    }

    private func markRemovedFlash(_ id: String) {
        guard var a = adder else { return }
        a.removedFlashID = id
        a.removedFlashUntil = Date().addingTimeInterval(AppAdder.removedFlashSeconds)
        a.message = nil
        a.failed = false
        adder = a
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(AppAdder.removedFlashSeconds))
            self?.clearRemovedFlash(id)
        }
    }

    private func clearRemovedFlash(_ id: String) {
        guard var a = adder, a.removedFlashID == id else { return }
        a.removedFlashID = nil
        a.removedFlashUntil = nil
        adder = a
    }

    private func finishSheet(focusID: String, message: String) {
        adder?.message = message
        adder?.failed = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, self.adder != nil else { return }
            self.adder = nil
            if let index = self.services.firstIndex(where: { $0.id == focusID }) {
                self.setFocus(.app(index))
            }
        }
    }
}
