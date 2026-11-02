import AppKit

// Focus on the home screen: the app grid, the Top Shelf and the status row.
extension TVController {
    var statusItems: [StatusItem] {
        (lidSleepOff ? [.lid] : []) + [.controlCenter, .profile]
    }

    /// The top-row app whose content the Top Shelf shows.
    var shelfService: Service { services.indices.contains(shelfAppIndex) ? services[shelfAppIndex] : services[0] }

    /// True when focus is below the top row; the Top Shelf scrolls away.
    var inGrid: Bool {
        if case .app(let index) = focus { return index >= columns }
        return false
    }

    /// How many things in the Top Shelf can take focus: its Open button, for apps.
    var shelfCount: Int {
        switch shelfService.kind {
        case .web, .app, .steam, .movies: return TopShelfFeed.shared.searchURL(for: shelfService) == nil ? 1 : 2
        case .addApp, .settings: return 0
        }
    }

    func hover(_ index: Int, tilt: CGSize) {
        guard !suppressHover else { return }
        switch focus {
        case .shelf, .status: return
        case .app: break
        }
        guard (index >= columns) == inGrid else { return }
        if focus != .app(index) { Feedback.shared.play(.move, from: .pointer) }
        setFocus(.app(index))
        self.tilt = tilt
    }

    func moveFocus(_ direction: RemoteCommand.Direction) {
        switch focus {
        case .app(let index):
            let row = index / columns, column = index % columns
            switch direction {
            case .left:
                if column > 0 { setFocus(.app(index - 1)) }
            case .right:
                if column < columns - 1, index + 1 < services.count { setFocus(.app(index + 1)) }
            case .down:
                if index + columns < services.count {
                    setFocus(.app(index + columns))
                } else if (row + 1) * columns < services.count {
                    setFocus(.app(services.count - 1))
                }
            case .up:
                if row > 0 {
                    setFocus(.app(index - columns))
                } else if shelfCount > 0 {
                    setFocus(.shelf(0))
                } else {
                    setFocus(.status(.controlCenter))
                }
            }
        case .shelf(let index):
            switch direction {
            case .left: if index > 0 { setFocus(.shelf(index - 1)) }
            case .right: if index + 1 < shelfCount { setFocus(.shelf(index + 1)) }
            case .down: setFocus(.app(shelfAppIndex))
            case .up: setFocus(.status(.controlCenter))
            }
        case .status(let item):
            let items = statusItems
            let index = items.firstIndex(of: item) ?? items.firstIndex(of: .controlCenter) ?? 0
            switch direction {
            case .left: setFocus(.status(items[max(0, index - 1)]))
            case .right: setFocus(.status(items[min(items.count - 1, index + 1)]))
            case .down: setFocus(shelfCount > 0 ? .shelf(0) : .app(shelfAppIndex))
            case .up: break
            }
        }
    }

    func activateStatus(_ item: StatusItem) {
        setFocus(.status(item))
        switch item {
        case .lid: settings = SettingsPanel(section: .power, open: true, row: 1)
        case .controlCenter: openControlCenter()
        case .profile: openProfiles()
        }
    }

    func activateShelf(_ index: Int) {
        if index == 0, let url = TopShelfFeed.shared.searchURL(for: shelfService) {
            playbackCoordinator.playWeb(shelfService, url: url)
        } else {
            open(shelfService)
        }
    }
}
