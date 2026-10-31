import AppKit

/// The TV's own add-app sheet: a website by address, or a Mac app from the installed ones.
/// It's driven entirely by the D-pad and typing, from the keyboard or the phone remote.
struct AppAdder: Equatable {
    enum Tab { case website, macApp, steam }

    var tab: Tab = .website
    /// Website: 0 tabs, 1 address, 2 name, 3 the add button. Mac app: 0 tabs, 1 search, 2 the list.
    /// Steam: 0 tabs, 1 the list.
    var row = 1
    var address = ""
    var name = ""
    var query = ""
    /// The highlighted app in the Mac app or Steam list.
    var selected = 0
    var message: String?
    var failed = false
}

extension TVController {
    var adderMatches: [InstalledApps.App] { InstalledApps.matching(adder?.query ?? "") }

    /// The tabs on offer: Steam only when it's installed.
    var adderTabs: [AppAdder.Tab] { SteamLibrary.isInstalled ? [.website, .macApp, .steam] : [.website, .macApp] }

    /// Steam Big Picture, then every installed game.
    var adderSteamGames: [SteamLibrary.Game] { [SteamLibrary.bigPicture] + SteamLibrary.installedGames() }

    func isOnHomeScreen(_ game: SteamLibrary.Game) -> Bool {
        services.contains { $0.kind == .steam(appID: game.appID) }
    }

    func isOnHomeScreen(_ app: InstalledApps.App) -> Bool {
        services.contains { $0.kind == .app(bundleID: app.bundleID) }
    }

    func handleAdder(_ command: RemoteCommand) {
        guard var a = adder else { return }
        let lastRow = a.tab == .website ? 3 : a.tab == .macApp ? 2 : 1
        let tabs = adderTabs
        let tabIndex = tabs.firstIndex(of: a.tab) ?? 0
        a.message = nil
        switch command {
        case .back:
            adder = nil
            return
        case .move(let direction) where direction == .left || direction == .right:
            if a.row == 0 {
                let step = direction == .right ? 1 : tabs.count - 1
                a.tab = tabs[(tabIndex + step) % tabs.count]
                a.selected = 0
            }
        case .move(.up):
            let inList = (a.tab == .macApp && a.row == 2) || (a.tab == .steam && a.row == 1)
            if inList, a.selected > 0 { a.selected -= 1 } else { a.row = max(0, a.row - 1) }
        case .move(.down):
            if a.tab == .macApp, a.row == 2 {
                a.selected = min(a.selected + 1, max(adderMatches.count - 1, 0))
            } else if a.tab == .steam, a.row == 1 {
                a.selected = min(a.selected + 1, adderSteamGames.count - 1)
            } else if !(a.tab == .macApp && a.row == 1 && adderMatches.isEmpty) {
                a.row = min(lastRow, a.row + 1)
            }
        case .select:
            switch (a.tab, a.row) {
            case (_, 0): a.tab = tabs[(tabIndex + 1) % tabs.count]; a.row = 1; a.selected = 0
            case (.website, 3): adder = a; submitAdder(); return
            case (.macApp, 2): adder = a; addSelectedMacApp(); return
            case (.steam, 1): adder = a; addSelectedSteamGame(); return
            default: a.row = min(lastRow, a.row + 1)
            }
        case .text(let text):
            let typed = text.replacingOccurrences(of: "\n", with: "")
            switch (a.tab, a.row) {
            case (.website, 2): a.name += typed
            case (.website, _): a.row = max(a.row, 1) == 3 ? 1 : max(a.row, 1); a.address += typed
            case (.macApp, _): a.row = 1; a.query += typed; a.selected = 0
            case (.steam, _): break
            }
            if text.hasSuffix("\n") { adder = a; handleAdder(.select); return }
        case .deleteBackward:
            switch (a.tab, a.row) {
            case (.website, 2): if !a.name.isEmpty { a.name.removeLast() }
            case (.website, _): if !a.address.isEmpty { a.address.removeLast() }
            case (.macApp, _): if !a.query.isEmpty { a.query.removeLast() }; a.selected = 0
            case (.steam, _): break
            }
        default:
            break
        }
        adder = a
    }

    func submitAdder() {
        guard var a = adder else { return }
        guard let app = addWebsite(name: a.name, address: a.address) else {
            a.message = a.address.isEmpty ? "Type a website address first." : "That doesn't look like a website address."
            a.failed = true
            adder = a
            return
        }
        finishAdding(app, message: "Added \(app.name). Finding its icon…")
    }

    func addSelectedMacApp() {
        guard var a = adder else { return }
        let matches = adderMatches
        guard matches.indices.contains(a.selected) else { return }
        let pick = matches[a.selected]
        if isOnHomeScreen(pick) {
            a.message = "\(pick.name) is already on the home screen."
            a.failed = true
            adder = a
            return
        }
        guard let app = addMacApp(bundleID: pick.bundleID) else { return }
        finishAdding(app, message: "Added \(app.name).")
    }

    func addSelectedSteamGame() {
        guard var a = adder else { return }
        let games = adderSteamGames
        guard games.indices.contains(a.selected) else { return }
        let pick = games[a.selected]
        if isOnHomeScreen(pick) {
            a.message = "\(pick.name) is already on the home screen."
            a.failed = true
            adder = a
            return
        }
        guard let app = addSteamGame(pick) else { return }
        finishAdding(app, message: pick == SteamLibrary.bigPicture ? "Added Steam Big Picture." : "Added \(app.name). Getting its artwork from Steam…")
    }

    /// Shows the confirmation, then closes the sheet with the new tile focused.
    private func finishAdding(_ app: AddedApp, message: String) {
        adder?.message = message
        adder?.failed = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, self.adder != nil else { return }
            self.adder = nil
            if let index = self.services.firstIndex(where: { $0.id == app.id }) {
                self.setFocus(.app(index))
            }
        }
    }
}
