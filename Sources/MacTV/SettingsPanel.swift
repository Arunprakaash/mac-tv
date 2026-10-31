import SwiftUI

/// The TV's Settings: a list of sections, each opening a page of its own, with the focused
/// section's symbol large on the left like tvOS. Driven by the D-pad, the keyboard or the mouse.
struct SettingsPanel: Equatable {
    enum Section: Int, CaseIterable {
        case profiles, remotes, watching, screenSaver, sounds, apps, movies, dedicatedTV, power, about
    }

    /// One row on a section's page.
    enum Row: Equatable {
        case phoneRemote, pairingCode, controller
        case sleepTimer, autoSkip, autoNext, playbackCheck, websitePlayer
        case addApp, arrangeApps, topShelfPreferences
        case dedicatedTV, preferredDisplay, launchAtLogin
        case wallpaper, aerialCategory, saverDelay, saverClock, saverPreview
        case feedback
        case keepMacAwake, lidOverride, screenOff, sleepMac
        case version, source, analytics
    }

    var section: Section = .profiles
    /// On the section's own page rather than the list of sections.
    var open = false
    var row = 0
    /// Sleep Mac asks for a second press, like the phone remote's double tap.
    var confirmingSleep = false
}

extension SettingsPanel.Section {
    var title: String {
        switch self {
        case .profiles: "Profiles"
        case .remotes: "Remotes and Devices"
        case .watching: "Watching"
        case .screenSaver: "Screen Saver"
        case .sounds: "Sounds and Haptics"
        case .apps: "Apps"
        case .movies: "Movies"
        case .dedicatedTV: "Dedicated TV"
        case .power: "Power"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .profiles: "person.2.fill"
        case .remotes: "appletvremote.gen4.fill"
        case .watching: "play.tv.fill"
        case .screenSaver: "sparkles.tv.fill"
        case .sounds: "speaker.wave.2.fill"
        case .apps: "square.grid.2x2.fill"
        case .movies: "film.stack.fill"
        case .dedicatedTV: "tv.fill"
        case .power: "bolt.fill"
        case .about: "info.circle"
        }
    }

    var blurb: String {
        switch self {
        case .profiles: "Everyone gets their own apps and stays signed in separately."
        case .remotes: "Use your phone as a remote, and see your game controllers."
        case .watching: "Skip intros and recaps, play the next episode, and set a sleep timer."
        case .screenSaver: "Shown after a few idle minutes on the home screen. Any press brings you back."
        case .sounds: "Quiet clicks as you move around, and a tap on the trackpad or controller."
        case .apps: "Add any website, Mac app or Steam game to the home screen."
        case .movies: "Play the video files in your folders, MKV included."
        case .dedicatedTV: "Choose a display and start Mac TV automatically."
        case .power: "Keep the Mac awake for the remote, and choose what closing the lid does."
        case .about: "Mac TV is free and open source."
        }
    }

    /// The rows on its page; empty for sections that open somewhere else.
    @MainActor var rows: [SettingsPanel.Row] {
        switch self {
        case .remotes: [.phoneRemote, .pairingCode, .controller]
        case .watching: [.sleepTimer, .autoSkip, .autoNext, .playbackCheck, .websitePlayer]
        case .screenSaver: ScreenSaverSettings.wallpaper == .aerials && !Aerials.categories.isEmpty
            ? [.wallpaper, .aerialCategory, .saverDelay, .saverClock, .saverPreview]
            : [.wallpaper, .saverDelay, .saverClock, .saverPreview]
        case .sounds: [.feedback]
        case .apps: [.addApp, .arrangeApps, .topShelfPreferences]
        case .dedicatedTV: [.dedicatedTV, .preferredDisplay, .launchAtLogin]
        case .power: [.keepMacAwake, .lidOverride, .screenOff, .sleepMac]
        case .about: Analytics.available ? [.version, .source, .analytics] : [.version, .source]
        case .profiles, .movies: []
        }
    }
}

extension TVController {
    static let sleepTimerSteps = [0, 15, 30, 60, 90]

    /// Minutes left on the sleep timer; 0 when it's off.
    var sleepMinutesLeft: Int {
        sleepAt.map { max(1, Int(($0.timeIntervalSinceNow / 60).rounded(.up))) } ?? 0
    }

    func openSettings() {
        settings = SettingsPanel()
        // Nothing to set before there's a remote: go straight to the QR code.
        if !phonePaired { pairing = true }
    }

    func handleSettings(_ command: RemoteCommand) {
        guard var panel = settings else { return }
        if case .select = command {} else { panel.confirmingSleep = false }

        guard panel.open else {
            let sections = SettingsPanel.Section.allCases
            switch command {
            case .back:
                settings = nil
                return
            case .move(.up):
                panel.section = sections[max(0, panel.section.rawValue - 1)]
            case .move(.down):
                panel.section = sections[min(sections.count - 1, panel.section.rawValue + 1)]
            case .move(.right), .select:
                settings = panel
                openSection(panel.section)
                return
            default:
                break
            }
            settings = panel
            return
        }

        let rows = panel.section.rows
        // Left steps or switches off a row that has a value; on any other row it goes back.
        let adjustable: Set<String> = ["sleepTimer", "wallpaper", "aerialCategory", "saverDelay", "saverClock", "feedback",
                                       "autoSkip", "autoNext", "websitePlayer", "dedicatedTV", "preferredDisplay", "launchAtLogin",
                                       "keepMacAwake", "lidOverride", "analytics"]
        switch command {
        case .back:
            panel.open = false
            panel.row = 0
        case .move(.left) where !adjustable.contains(String(describing: rows[panel.row])):
            panel.open = false
            panel.row = 0
        case .move(.up):
            panel.row = max(0, panel.row - 1)
        case .move(.down):
            panel.row = min(rows.count - 1, panel.row + 1)
        case .move(let direction) where direction == .left || direction == .right:
            settings = panel
            adjustSetting(rows[panel.row], forward: direction == .right)
            return
        case .select:
            settings = panel
            activateSetting(rows[panel.row])
            return
        default:
            break
        }
        settings = panel
    }

    /// Opens a section's page, or goes where the section lives.
    func openSection(_ section: SettingsPanel.Section) {
        Analytics.send(.settingsOpened, ["section": String(describing: section)])
        switch section {
        case .profiles:
            openProfiles()
        case .movies:
            settings = nil
            openMovies()
        default:
            settings?.section = section
            settings?.open = true
            settings?.row = 0
        }
    }

    /// Left and right: step a value, or switch a setting off and on.
    private func adjustSetting(_ row: SettingsPanel.Row, forward: Bool) {
        switch row {
        case .dedicatedTV: setDedicatedTVMode(forward)
        case .preferredDisplay: stepTVDisplay(forward ? 1 : -1)
        case .launchAtLogin: setLaunchAtLogin(forward)
        case .sleepTimer: stepSleepTimer(by: forward ? 1 : -1, wrap: false)
        case .websitePlayer: stepWebsitePlayer()
        case .wallpaper: ScreenSaverSettings.step(forward ? 1 : -1)
        case .aerialCategory: ScreenSaverSettings.stepAerialCategory(forward ? 1 : -1)
        case .saverDelay: ScreenSaverSettings.stepDelay(forward ? 1 : -1)
        case .saverClock: ScreenSaverSettings.showClock = forward
        case .feedback: Feedback.shared.enabled = forward
        case .autoSkip: autoSkip = forward
        case .autoNext: autoNext = forward
        case .keepMacAwake: keepMacAwake = forward
        case .lidOverride: lidOverride = forward
        case .analytics: Analytics.setConsent(forward, context: analyticsContext)
        default: return
        }
        objectWillChange.send()
    }

    func activateSetting(_ row: SettingsPanel.Row) {
        if let index = settings?.section.rows.firstIndex(of: row) { settings?.row = index }
        switch row {
        case .phoneRemote: pairing = true
        case .pairingCode: break
        case .controller:
            showToast(controller == nil ? "Pair a controller in System Settings › Bluetooth" : "Press its Menu button any time to come home")
        case .addApp:
            settings = nil
            adder = AppAdder()
        case .arrangeApps: openOrganizer()
        case .topShelfPreferences: openTopShelfPreferences()
        case .playbackCheck: openPlaybackCheck()
        case .dedicatedTV: setDedicatedTVMode(!dedicatedTVMode)
        case .preferredDisplay: stepTVDisplay(1, wrap: true)
        case .launchAtLogin: setLaunchAtLogin(!launchAtLogin)
        case .sleepTimer: stepSleepTimer(by: 1, wrap: true)
        case .websitePlayer: stepWebsitePlayer()
        case .autoSkip: autoSkip.toggle()
        case .autoNext: autoNext.toggle()
        case .wallpaper:
            if ScreenSaverSettings.wallpaper == .photos { ScreenSaverSettings.choosePhotosFolder() } else { ScreenSaverSettings.step(1) }
        case .aerialCategory: ScreenSaverSettings.stepAerialCategory(1, wrap: true)
        case .saverDelay: ScreenSaverSettings.stepDelay(1, wrap: true)
        case .saverClock: ScreenSaverSettings.showClock.toggle()
        case .saverPreview:
            settings = nil
            showScreensaver()
        case .feedback: Feedback.shared.enabled.toggle()
        case .keepMacAwake: keepMacAwake.toggle()
        case .lidOverride: lidOverride.toggle()
        case .screenOff: SystemControl.displayOff()
        case .sleepMac:
            if settings?.confirmingSleep == true {
                goHome()
                SystemControl.sleepNow()
            } else {
                settings?.confirmingSleep = true
            }
        case .version, .source: break
        case .analytics: Analytics.setConsent(!Analytics.enabled, context: analyticsContext)
        }
        objectWillChange.send()
    }

    /// Moves the sleep timer to the next or previous step: Off, 15, 30, 60, 90 minutes.
    func stepSleepTimer(by step: Int, wrap: Bool) {
        let steps = Self.sleepTimerSteps
        let current = steps.firstIndex { $0 >= sleepMinutesLeft } ?? 0
        var next = current + step
        next = wrap ? (next + steps.count) % steps.count : min(max(next, 0), steps.count - 1)
        guard next != current else { return }
        setSleepTimer(minutes: steps[next])
    }

    /// The short summary beside each section in the list.
    func settingsDetail(_ section: SettingsPanel.Section) -> String {
        switch section {
        case .profiles: return profiles.all.map(\.name).joined(separator: ", ")
        case .remotes:
            let parts = [phonePaired ? "Phone" : nil, controller?.name].compactMap { $0 }
            return parts.isEmpty ? "Set up" : parts.joined(separator: " · ")
        case .watching: return autoSkip ? "Skips intros" : "Intros play"
        case .screenSaver: return "\(ScreenSaverSettings.wallpaper.title) · \(ScreenSaverSettings.delayMinutes) min"
        case .sounds: return Feedback.shared.enabled ? "On" : "Off"
        case .apps: return "\(services.filter { $0.kind != .settings && $0.kind != .addApp }.count) on Home"
        case .movies:
            let count = MovieLibrary.shared.folders.count
            return "\(count) folder\(count == 1 ? "" : "s")"
        case .dedicatedTV: return dedicatedTVMode ? "On · \(preferredTVDisplayName)" : "Off"
        case .power: return keepMacAwake ? "Keeps Mac awake" : "Sleeps as usual"
        case .about: return "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")"
        }
    }
}

// MARK: Views

struct SettingsSheet: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas
    @Namespace private var focusSpace

    var body: some View {
        let panel = tv.settings ?? SettingsPanel()
        HStack(spacing: 0) {
            hero(panel.section)
                .frame(width: 780, alignment: .leading)
                .padding(.leading, 120)
            Group {
                if panel.open {
                    page(panel)
                } else {
                    sections(panel)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, 120)
            .padding(.leading, 20)
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.focus, value: panel)
    }

    private func hero(_ section: SettingsPanel.Section) -> some View {
        VStack(alignment: .leading, spacing: 34) {
            Text("SETTINGS").font(.tv(.caption2, emphasized: true)).tracking(1.6).opacity(0.5)
            Image(systemName: section.symbol)
                .font(.system(size: 130, weight: .regular))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 300, height: 300)
                // A plain tile, not glass: Settings sits on a frosted backdrop, and glass there would read flat.
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 72, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 72, style: .continuous).strokeBorder(.white.opacity(0.14)))
            VStack(alignment: .leading, spacing: 14) {
                Text(section.title).font(.tv(.title2, emphasized: true))
                Text(section.blurb).font(.tv(.caption1)).foregroundStyle(.white.opacity(0.68))
                    .lineSpacing(5).frame(maxWidth: 560, alignment: .leading)
            }
            .id(section)
            .transition(.opacity)
        }
        .animation(Motion.appear, value: section)
    }

    private func sections(_ panel: SettingsPanel) -> some View {
        VStack(spacing: 10) {
            ForEach(SettingsPanel.Section.allCases, id: \.self) { section in
                let focused = panel.section == section
                row(focused: focused, warning: false) {
                    Image(systemName: section.symbol).font(.system(size: 27, weight: .medium))
                        .frame(width: 40).opacity(0.9)
                    Text(section.title).font(.tv(.body))
                    Spacer(minLength: 16)
                    Text(tv.settingsDetail(section)).font(.tv(.caption1)).opacity(0.55).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold)).opacity(0.4)
                } action: {
                    tv.settings?.section = section
                    tv.openSection(section)
                }
            }
        }
    }

    @ViewBuilder
    private func page(_ panel: SettingsPanel) -> some View {
        let rows = panel.section.rows
        VStack(alignment: .leading, spacing: 10) {
            if panel.section == .power {
                Text(tv.lidStatus).font(.tv(.caption2)).foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 6).padding(.bottom, 6)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                let focused = panel.row == index
                if row == .wallpaper {
                    wallpapers(focused: focused)
                } else if row == .aerialCategory {
                    aerialCategories(focused: focused)
                } else {
                    let warning = row == .sleepMac && panel.confirmingSleep
                    self.row(focused: focused, warning: warning) {
                        content(row, panel: panel)
                    } action: {
                        tv.activateSetting(row)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ row: SettingsPanel.Row, panel: SettingsPanel) -> some View {
        switch row {
        case .phoneRemote:
            title("Show QR Code", "Same Wi-Fi, or Tailscale away from home")
            chevron
        case .pairingCode:
            title("Pairing code")
            value(tv.remoteToken)
        case .controller:
            if let controller = tv.controller {
                title(controller.name, controller.battery.map { "Battery \(Int($0 * 100))%" } ?? "Connected")
                Image(systemName: controller.batterySymbol).font(.system(size: 26))
            } else {
                title("Game controller", "Pair one in System Settings › Bluetooth")
            }
        case .addApp:
            title("Add App", "Add a website, Mac app or Steam game")
            chevron
        case .arrangeApps:
            title("Arrange Apps", "Order and favourites")
            chevron
        case .topShelfPreferences:
            title("Top Shelf", "Choose sources")
            chevron
        case .playbackCheck:
            title("Playback check")
            chevron
        case .dedicatedTV:
            title(tv.dedicatedTVMode ? "Exit TV mode" : "Enter TV mode")
            SettingSwitch(on: tv.dedicatedTVMode)
        case .preferredDisplay:
            title("Preferred display")
            stepper(tv.preferredTVDisplayName, active: panel.section.rows[panel.row] == .preferredDisplay)
        case .launchAtLogin:
            title("Launch at login")
            if tv.loginNeedsApproval { value("Approval needed") }
            else { SettingSwitch(on: tv.launchAtLogin) }
        case .sleepTimer:
            title("Sleep timer")
            let minutes = tv.sleepMinutesLeft
            stepper(minutes == 0 ? "Off" : "\(minutes) min left", active: panel.row == 0)
        case .websitePlayer:
            title("Website player")
            stepper(tv.websitePlayerName, active: panel.section.rows[panel.row] == .websitePlayer)
        case .autoSkip:
            title("Skip intros and recaps")
            SettingSwitch(on: tv.autoSkip)
        case .autoNext:
            title("Play next episode automatically")
            SettingSwitch(on: tv.autoNext)
        case .saverDelay:
            title("Start after")
            stepper("\(ScreenSaverSettings.delayMinutes) minutes", active: tv.settings?.section.rows[panel.row] == .saverDelay)
        case .saverClock:
            title("Show clock")
            SettingSwitch(on: ScreenSaverSettings.showClock)
        case .saverPreview:
            title("Preview")
            chevron
        case .feedback:
            title("Sounds and haptics", "Clicks as you move, and taps on the trackpad and controller")
            SettingSwitch(on: Feedback.shared.enabled)
        case .keepMacAwake:
            title("Keep Mac awake while Mac TV is open")
            SettingSwitch(on: tv.keepMacAwake)
        case .lidOverride:
            title("Stay awake with lid closed")
            SettingSwitch(on: tv.lidOverride)
        case .screenOff:
            title("Turn screen off")
        case .sleepMac:
            title(panel.confirmingSleep ? "Press again to sleep the Mac" : "Sleep Mac")
        case .version:
            title("Version")
            value(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        case .source:
            title("Source code")
            value("github.com/Arunprakaash/mac-tv")
        case .analytics:
            title("Share anonymous usage", "Which features you use, never what you watch")
            SettingSwitch(on: Analytics.enabled)
        case .wallpaper, .aerialCategory:
            EmptyView()
        }
    }

    /// The screen saver's wallpapers, side by side; left and right choose one.
    private func wallpapers(focused: Bool) -> some View {
        let chosen = ScreenSaverSettings.wallpaper
        return VStack(alignment: .leading, spacing: 12) {
            Text("WALLPAPER").font(.tv(.caption2, emphasized: true)).tracking(1.4).opacity(0.5).padding(.leading, 6)
            HStack(spacing: 18) {
                ForEach(ScreenSaverSettings.Wallpaper.allCases, id: \.self) { wallpaper in
                    let selected = wallpaper == chosen
                    VStack(alignment: .leading, spacing: 10) {
                        WallpaperThumb(wallpaper: wallpaper)
                            .frame(height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .strokeBorder(.white.opacity(selected ? (focused ? 1 : 0.6) : 0.12), lineWidth: selected ? 4 : 1)
                            }
                            .overlay(alignment: .topTrailing) {
                                if selected {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 30))
                                        .symbolRenderingMode(.palette).foregroundStyle(.black, .white)
                                        .padding(10).transition(.scale.combined(with: .opacity))
                                }
                            }
                            .scaleEffect(selected && focused ? 1.05 : 1)
                            .shadow(color: .black.opacity(selected && focused ? 0.45 : 0), radius: 18, y: 12)
                        Text(wallpaper.title).font(.tv(.caption2))
                            .opacity(selected ? 1 : 0.6).padding(.leading, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        tv.settings?.row = 0
                        if selected, wallpaper == .photos { ScreenSaverSettings.choosePhotosFolder() }
                        ScreenSaverSettings.wallpaper = wallpaper
                        tv.objectWillChange.send()
                    }
                }
            }
            .animation(Motion.focus, value: chosen)
        }
        .padding(.bottom, 14)
    }

    /// Apple's live wallpaper categories, the same as System Settings › Wallpaper; left and right choose one.
    private func aerialCategories(focused: Bool) -> some View {
        let chosen = ScreenSaverSettings.aerialCategory
        let choices: [(id: String?, name: String)] = [(nil, "Shuffle All")] + Aerials.categories.map { ($0.id, $0.name) }
        // Two rows of four, so every name fits.
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 14) {
            ForEach(choices, id: \.name) { choice in
                let selected = choice.id == chosen
                VStack(alignment: .leading, spacing: 8) {
                    Color.clear
                        .overlay {
                            if let thumb = Aerials.thumbnail(forCategory: choice.id), let image = ScreenImages.image(thumb, maxPixels: 400) {
                                Image(nsImage: image).resizable().scaledToFill()
                            }
                        }
                        .frame(height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(selected ? (focused ? 1 : 0.6) : 0.12), lineWidth: selected ? 3 : 1)
                        }
                        .scaleEffect(selected && focused ? 1.06 : 1)
                    Text(choice.name).font(.tv(.caption2)).lineLimit(1)
                        .opacity(selected ? 1 : 0.6).padding(.leading, 2)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    ScreenSaverSettings.aerialCategory = choice.id
                    tv.objectWillChange.send()
                }
            }
        }
        .animation(Motion.focus, value: chosen)
        .padding(.bottom, 10)
    }

    // MARK: Pieces

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold)).opacity(0.4)
    }

    private func title(_ text: String, _ detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text).font(.tv(.body))
            if let detail { Text(detail).font(.tv(.caption2)).opacity(0.55) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.tv(.caption1)).monospacedDigit().opacity(0.55)
    }

    private func stepper(_ text: String, active: Bool) -> some View {
        HStack(spacing: 14) {
            if active { Image(systemName: "chevron.left").opacity(0.5) }
            Text(text).monospacedDigit().contentTransition(.numericText())
            if active { Image(systemName: "chevron.right").opacity(0.5) }
        }
        .font(.system(size: 24, weight: .semibold))
    }

    private func row<Content: View>(focused: Bool, warning: Bool, @ViewBuilder content: () -> Content,
                                    action: @escaping () -> Void) -> some View {
        HStack(spacing: 22) { content() }
            .padding(.horizontal, 30)
            .frame(minHeight: 78)
            // tvOS focus: a bright white platter with dark text; Sleep Mac turns red to confirm.
            .foregroundStyle(focused && !warning ? .black : .white)
            .background {
                let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
                if focused {
                    // One platter that glides from row to row as focus moves, like tvOS.
                    shape.fill(warning ? Color(hex: "#FF453A") : .white)
                        .matchedGeometryEffect(id: "focus", in: focusSpace)
                } else {
                    shape.fill(.white.opacity(0.07))
                }
            }
            .scaleEffect(focused ? 1.03 : 1)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 20, y: 12)
            .animation(Motion.focus, value: focused)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

/// An on/off switch drawn like the phone remote's.
struct SettingSwitch: View {
    let on: Bool

    var body: some View {
        Capsule()
            // Mid grey when off, so it shows on a dark row and on the white focus platter alike.
            .fill(on ? Color(hex: "#3DDC84") : Color(white: 0.55, opacity: 0.5))
            .frame(width: 64, height: 36)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 28, height: 28).padding(4)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
            .animation(.snappy(duration: 0.2), value: on)
    }
}
