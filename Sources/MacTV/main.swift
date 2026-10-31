import AVFoundation
import AppKit
import SwiftUI

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// The first external display, falling back to the main one.
    static var tvScreen: NSScreen {
        screens.first { CGDisplayIsBuiltin($0.displayID) == 0 } ?? main ?? screens[0]
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let tv = TVController()
    var window: NSWindow!
    var server: RemoteServer?
    var tvMode: TVMode?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest-drm") {
            DRMSelfTest.start()
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--export-remote"), flag + 1 < CommandLine.arguments.count {
            let sheet = flag + 2 < CommandLine.arguments.count ? CommandLine.arguments[flag + 2] : nil
            RemoteSnapshot.start(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]), sheet: sheet)
            return
        }
        // `--fullscreen-test <bundleID>` opens an app and puts its window in full screen the way a
        // launched game is, for checking without Steam games.
        if let flag = CommandLine.arguments.firstIndex(of: "--fullscreen-test"), flag + 1 < CommandLine.arguments.count,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CommandLine.arguments[flag + 1]) {
            print("Accessibility allowed:", AXIsProcessTrusted())
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, _ in
                guard let pid = app?.processIdentifier else { exit(1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    MainActor.assumeIsolated { print("Full screen:", GameWindow.makeFullScreen(pid: pid, on: NSScreen.main)) }
                    exit(0)
                }
            }
            return
        }
        // `--movie-probe <file> [frame.jpg]` prints what Mac TV makes of a video file: its title,
        // tracks and whether it plays here, and saves the frame a poster would use.
        if let flag = CommandLine.arguments.firstIndex(of: "--movie-probe"), flag + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            let frameFile = flag + 2 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[flag + 2]) : nil
            Task {
                let name = MovieName(url.deletingPathExtension().lastPathComponent)
                print("title: \(name.title)  year: \(name.year.map(String.init) ?? "-")  episode: \(name.episode ?? "-")")
                var frame: CGImage?
                if ["mkv", "webm"].contains(url.pathExtension.lowercased()) {
                    if let reader = try? MatroskaReader(url: url) {
                        print("duration: \(Double(reader.duration) / 1e9)s  cues: \(reader.cues.count)")
                        for track in reader.tracks {
                            print("track \(track.number): \(track.kind) \(track.codec) \(track.language) \(track.width)x\(track.height) \(track.sampleRate)Hz \(track.channels)ch")
                        }
                        var counts: [UInt64: Int] = [:]
                        for _ in 0..<500 { guard let block = reader.nextBlock() else { break }; counts[block.track, default: 0] += block.frames.count }
                        print("first 500 blocks, frames per track: \(counts)")
                    }
                    switch MatroskaPlayback.open(url) {
                    case .success(let engine): print("plays here: audio \(engine.audioOptions.map(\.title)), subtitles \(engine.subtitleOptions.map(\.title))")
                    case .failure(let problem): print("doesn't play here: \(problem)")
                    }
                    frame = MatroskaPlayback.frame(of: url, at: 0.12)
                } else {
                    switch await AVPlayback.open(url) {
                    case .success(let engine): print("plays here: \(engine.duration)s, audio \(engine.audioOptions.map(\.title))")
                    case .failure(let problem): print("doesn't play here: \(problem)")
                    }
                    frame = await AVPlayback.frame(of: url, at: 0.12)
                }
                print("frame: \(frame.map { "\($0.width)x\($0.height)" } ?? "none")")
                if let frame, let frameFile,
                   let jpeg = NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [:]) {
                    try? jpeg.write(to: frameFile)
                }
                exit(0)
            }
            return
        }
        // `--steam-games` prints the Steam games Mac TV finds (MACTV_STEAM_ROOT points at other Steam files).
        if CommandLine.arguments.contains("--steam-games") {
            let games = SteamLibrary.installedGames().map { ["appID": $0.appID, "name": $0.name] }
            if let data = try? JSONSerialization.data(withJSONObject: games, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            exit(0)
        }
        // `--steam-tile <appID> <file.png>` renders a game's tile from Steam's artwork.
        if let flag = CommandLine.arguments.firstIndex(of: "--steam-tile"), flag + 2 < CommandLine.arguments.count {
            let appID = CommandLine.arguments[flag + 1], file = URL(fileURLWithPath: CommandLine.arguments[flag + 2])
            Task {
                let png = await SteamLibrary.tile(for: appID)
                try? png?.write(to: file)
                print(png == nil ? "No artwork for \(appID)" : "Wrote \(file.path)")
                exit(png == nil ? 1 : 0)
            }
            return
        }
        // `--export-tiles <folder>` writes every dock tile as a PNG, for checking the icon layout.
        if let flag = CommandLine.arguments.firstIndex(of: "--export-tiles"), flag + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            for service in AppLibrary().services() {
                guard let tile = Icons.tile(for: service), let tiff = tile.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                try? png.write(to: folder.appendingPathComponent("\(service.id).png"))
            }
            exit(0)
        }
        // `--export-sounds <folder>` writes the interface sounds as WAV files, for listening to.
        if let flag = CommandLine.arguments.firstIndex(of: "--export-sounds"), flag + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            for cue in Feedback.Cue.allCases {
                guard let buffer = Feedback.synthesize(cue, format: format),
                      let file = try? AVAudioFile(forWriting: folder.appendingPathComponent("\(cue).wav"), settings: format.settings)
                else { continue }
                try? file.write(from: buffer)
            }
            exit(0)
        }
        // `--export-home <folder>` renders the home screen in a few focus states, for design checks.
        if let flag = CommandLine.arguments.firstIndex(of: "--export-home"), flag + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            let states: [(String, TVController.Focus)] = [("dock-netflix", .app(0)), ("dock-prime", .app(2)),
                                                          ("shelf-netflix", .shelf(0)), ("grid", .app(6))]
            // 16:9 for a TV, 16:10 for a MacBook screen.
            for (shape, canvas) in [("tv", CGSize(width: 1920, height: 1080)), ("mac", CGSize(width: 1920, height: 1200))] {
                for (name, focus) in states {
                    let tv = TVController()
                    if case .shelf = focus { tv.setFocus(.app(0)) }
                    tv.setFocus(focus)
                    let renderer = ImageRenderer(content: ZStack { Wallpaper(); HomeView(tv: tv) }
                        .environment(\.canvasSize, canvas)
                        .frame(width: canvas.width, height: canvas.height).environment(\.colorScheme, .dark))
                    renderer.scale = 1
                    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: folder.appendingPathComponent("\(shape)-\(name).png"))
                    }
                }
            }
            do {
                let tv = TVController()
                tv.settings = SettingsPanel(section: .power, open: true, row: 1)
                let renderer = ImageRenderer(content: ZStack { Wallpaper(); HomeView(tv: tv); Color.black.opacity(0.55); SettingsSheet(tv: tv) }
                    .frame(width: 1920, height: 1080).environment(\.colorScheme, .dark))
                renderer.scale = 1
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: folder.appendingPathComponent("settings.png"))
                }
            }
            for (name, adder) in [("add-website", AppAdder(tab: .website, row: 1, address: "crunchyroll.co")),
                                  ("add-macapp", AppAdder(tab: .macApp, row: 2, query: "", selected: 1))] {
                let tv = TVController()
                tv.adder = adder
                let renderer = ImageRenderer(content: ZStack { Wallpaper(); HomeView(tv: tv); Color.black.opacity(0.55); AddAppSheet(tv: tv) }
                    .frame(width: 1920, height: 1080).environment(\.colorScheme, .dark))
                renderer.scale = 1
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: folder.appendingPathComponent("\(name).png"))
                }
            }
            for (name, flow) in [("setup-welcome", SetupFlow()), ("setup-apps", SetupFlow(step: .apps, index: 1)),
                                 ("setup-remote", SetupFlow(step: .remote)), ("setup-done", SetupFlow(step: .done))] {
                let tv = TVController()
                tv.setup = flow
                let renderer = ImageRenderer(content: ZStack { Wallpaper(); HomeView(tv: tv); Color.black.opacity(0.7); SetupScreen(tv: tv) }
                    .environment(\.canvasSize, CGSize(width: 1920, height: 1080))
                    .frame(width: 1920, height: 1080).environment(\.colorScheme, .dark))
                renderer.scale = 1
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: folder.appendingPathComponent("\(name).png"))
                }
            }
            let saver = ImageRenderer(content: Screensaver().frame(width: 1920, height: 1080).environment(\.colorScheme, .dark))
            saver.scale = 1
            if let image = saver.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("screensaver.png"))
            }
            exit(0)
        }

        NSApp.mainMenu = makeMainMenu()

        // A normal window; the green button or ⌃⌘F takes it full screen.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Mac TV"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 640, height: 360)
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView(tv: tv))
        tv.window = window
        if !window.setFrameUsingName("MacTVWindow") { placeOnTV() }
        window.setFrameAutosaveName("MacTVWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        tvMode = TVMode(window: window, tv: tv)
        tvMode?.start()

        startRemoteServer()
        installLauncherKeys()
        tv.startPowerManagement()
        tv.startControllers()
        TopShelfFeed.shared.start()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // `--setup` shows first-run setup again.
        if tv.needsSetup || CommandLine.arguments.contains("--setup") {
            tv.startSetup()
        } else if tv.profiles.all.count > 1 {
            tv.openProfiles()
        } else if !tv.phonePaired {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.tv.showToast("Pair your phone as a remote: open Settings below")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        tv.closeExternalBrowser()
        tv.stopPowerManagement()
    }

    /// First launch: a 16:9 window filling most of the TV display.
    private func placeOnTV() {
        let area = NSScreen.tvScreen.visibleFrame
        var size = NSSize(width: area.width * 0.8, height: area.width * 0.8 * 9 / 16)
        if size.height > area.height * 0.85 {
            size = NSSize(width: area.height * 0.85 * 16 / 9, height: area.height * 0.85)
        }
        window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
    }

    @objc private func screensChanged() {
        tvMode?.screensChanged()
        tv.refreshRemoteURL()
        tv.refreshPower()
    }

    private func startRemoteServer() {
        let token = RemoteServer.pairingCode()
        tv.remoteToken = token
        let server = RemoteServer(
            token: token,
            onCommand: { [weak self] in self?.tv.handle($0, from: .remote) },
            state: { [weak self] in self?.tv.remoteState() ?? [:] },
            icon: { [weak self] in self?.tv.iconPNG(for: $0) },
            routes: { [weak self] in self?.tv.handleAppsRequest($0) })
        server.start(ports: Array(8765...8775)) { [weak self] port in self?.tv.remotePort = port }
        self.server = server
    }

    private var scrollTotal: CGFloat = 0
    private var scrollReadyAt = Date.distantPast

    /// Arrows, Return and Escape drive the home screen. In a player, keys go to the page.
    /// Trackpad or wheel scrolling moves between the Top Shelf, the dock and the grid.
    private func installLauncherKeys() {
        // Any pointer input counts as activity; a click that only wakes the screensaver goes no further.
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === window else { return event }
            let woke = tv.noteActivity()
            return woke && event.type == .leftMouseDown ? nil : event
        }
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === window else { return event }
            if tv.noteActivity() { return nil }
            guard tv.mode == .launcher, !tv.pairing, tv.settings == nil, tv.adder == nil,
                  tv.organizer == nil, tv.playbackCheck == nil, tv.topShelfPreferences == nil,
                  tv.setup == nil, tv.profilePicker == nil, tv.controlCenter == nil else { return event }
            // One move per swipe: ignore momentum, and pause briefly after each move.
            guard event.momentumPhase.isEmpty else { return nil }
            if event.phase == .began { scrollTotal = 0 }
            scrollTotal += event.scrollingDeltaY
            if abs(scrollTotal) > 30, Date() >= scrollReadyAt {
                // Content follows the fingers: swiping up reveals what's below.
                tv.handle(.move(scrollTotal < 0 ? .down : .up), from: .trackpad)
                scrollTotal = 0
                scrollReadyAt = Date().addingTimeInterval(0.45)
            }
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let tv = self?.tv, event.window === self?.window else { return event }
            if tv.noteActivity() { return nil }
            guard tv.mode == .launcher || tv.mode == .movie else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
            // The add-app sheet takes typing: letters, Space, Delete and ⌘V go to its fields.
            // So does naming a new profile.
            if tv.adder != nil || tv.profilePicker?.naming != nil {
                if mods == [.command], event.charactersIgnoringModifiers == "v",
                   let pasted = NSPasteboard.general.string(forType: .string) {
                    tv.handle(.text(pasted))
                    return nil
                }
                if mods.isEmpty, event.keyCode == 51 {
                    tv.handle(.deleteBackward)
                    return nil
                }
                let navigation: Set<UInt16> = [123, 124, 125, 126, 36, 76, 53]
                if !navigation.contains(event.keyCode), mods.subtracting(.shift).isEmpty,
                   let typed = event.characters, !typed.isEmpty,
                   typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    tv.handle(.text(typed))
                    return nil
                }
            }
            guard mods.isEmpty else { return event }
            switch event.keyCode {
            case 123: tv.handle(.move(.left))
            case 124: tv.handle(.move(.right))
            case 125: tv.handle(.move(.down))
            case 126: tv.handle(.move(.up))
            case 36, 76, 49: tv.handle(.select)
            case 53: tv.handle(.back)
            default: return event
            }
            return nil
        }
    }

    @objc func goHome(_ sender: Any?) { tv.handle(.home) }
    @objc func reloadPage(_ sender: Any?) { tv.webView?.reload() }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Home", action: #selector(goHome(_:)), keyEquivalent: "H")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Mac TV", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Mac TV", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Mac TV")

        // Standard editing so ⌘V works in sign-in fields.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        view.addItem(withTitle: "Reload Page", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        main.addItem(submenu: view, title: "View")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

// `--lid-guard <pid>`: the helper that restores lid sleep once Mac TV exits (see LidSleep).
if let flag = CommandLine.arguments.firstIndex(of: "--lid-guard"), flag + 1 < CommandLine.arguments.count,
   let parent = pid_t(CommandLine.arguments[flag + 1]) {
    LidSleep.runGuard(parent: parent)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
