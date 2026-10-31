import AppKit

/// The TV's own add-app sheet: a website by address, or a Mac app from the installed ones.
/// It's driven entirely by the D-pad and typing, from the keyboard or the phone remote.
struct AppAdder: Equatable {
    enum Tab { case website, macApp }

    var tab: Tab = .website
    /// Website: 0 tabs, 1 address, 2 name, 3 the add button. Mac app: 0 tabs, 1 search, 2 the list.
    var row = 1
    var address = ""
    var name = ""
    var query = ""
    /// The highlighted app in the Mac app list.
    var selected = 0
    var message: String?
    var failed = false
}

extension TVController {
    var adderMatches: [InstalledApps.App] { InstalledApps.matching(adder?.query ?? "") }

    func isOnHomeScreen(_ app: InstalledApps.App) -> Bool {
        services.contains { $0.kind == .app(bundleID: app.bundleID) }
    }

    func handleAdder(_ command: RemoteCommand) {
        guard var a = adder else { return }
        let lastRow = a.tab == .website ? 3 : 2
        a.message = nil
        switch command {
        case .back:
            adder = nil
            return
        case .move(.left), .move(.right):
            if a.row == 0 {
                a.tab = a.tab == .website ? .macApp : .website
                a.selected = 0
            }
        case .move(.up):
            if a.tab == .macApp, a.row == 2, a.selected > 0 { a.selected -= 1 } else { a.row = max(0, a.row - 1) }
        case .move(.down):
            if a.tab == .macApp, a.row == 2 {
                a.selected = min(a.selected + 1, max(adderMatches.count - 1, 0))
            } else if !(a.tab == .macApp && a.row == 1 && adderMatches.isEmpty) {
                a.row = min(lastRow, a.row + 1)
            }
        case .select:
            switch (a.tab, a.row) {
            case (_, 0): a.tab = a.tab == .website ? .macApp : .website; a.row = 1; a.selected = 0
            case (.website, 3): adder = a; submitAdder(); return
            case (.macApp, 2): adder = a; addSelectedMacApp(); return
            default: a.row = min(lastRow, a.row + 1)
            }
        case .text(let text):
            let typed = text.replacingOccurrences(of: "\n", with: "")
            switch (a.tab, a.row) {
            case (.website, 2): a.name += typed
            case (.website, _): a.row = max(a.row, 1) == 3 ? 1 : max(a.row, 1); a.address += typed
            case (.macApp, _): a.row = 1; a.query += typed; a.selected = 0
            }
            if text.hasSuffix("\n") { adder = a; handleAdder(.select); return }
        case .deleteBackward:
            switch (a.tab, a.row) {
            case (.website, 2): if !a.name.isEmpty { a.name.removeLast() }
            case (.website, _): if !a.address.isEmpty { a.address.removeLast() }
            case (.macApp, _): if !a.query.isEmpty { a.query.removeLast() }; a.selected = 0
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
