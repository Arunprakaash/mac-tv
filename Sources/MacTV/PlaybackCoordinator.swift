import AppKit
import SwiftUI
import WebKit

/// Manages web player, native movie player, IINA sessions, and external browser playback.
@MainActor
final class PlaybackCoordinator: NSObject, ObservableObject {
    weak var tv: TVController?

    // Web Playback
    @Published private(set) var webView: WKWebView?
    private var popups: [NSWindow] = []

    // Native Movie Playback
    @Published private(set) var moviePlayer: MoviePlayer?
    @Published private(set) var currentLocalMovie: Movie?
    private(set) var localMoviePlayer = "native"

    // IINA Playback
    private var iinaSession: IINAPlaybackSession?
    @Published private(set) var iinaPlaybackError: String?
    @Published private(set) var iinaPlaybackStatus = ""

    // External Browser (Brave)
    @Published private(set) var externalBrowser: BraveSession?
    @Published private(set) var externalBrowserService: Service?
    @Published private(set) var externalBrowserError: String?
    @Published private(set) var externalBrowserOpening = false

    private var playbackRequest = UUID()

    init(tv: TVController? = nil) {
        self.tv = tv
        super.init()
    }

    var isAnyPlaybackActive: Bool {
        iinaSession != nil || externalBrowser != nil || moviePlayer != nil || webView != nil
    }

    var iinaRunning: Bool {
        iinaSession?.isRunning == true
    }

    func resetPlaybackRequest() {
        playbackRequest = UUID()
    }

    func clearCurrentLocalMovie() {
        currentLocalMovie = nil
        tv?.objectWillChange.send()
    }

    func stopMoviePlayer() {
        if let player = moviePlayer {
            player.stop()
            moviePlayer = nil
            tv?.objectWillChange.send()
        }
    }

    // MARK: - Web Playback

    func playWeb(_ service: Service, url: URL) {
        if tv?.browserPreferences.choice(for: tv?.profile.id ?? "").rawValue == BrowserChoice.brave.rawValue {
            playInBrave(service, url: url)
            return
        }
        playbackRequest = UUID()
        currentLocalMovie = nil
        tv?.playerFailure = nil
        let web = makeWebView(for: service)
        web.load(URLRequest(url: url))
        webView = web
        tv?.setMode(.player(service))
        tv?.clearPointer()
        tv?.displayCoordinator.holdPlaybackKeepAwake(reason: "Watching \(service.name) in Mac TV")
        tv?.bringToFront()
        Task { @MainActor [weak self] in self?.tv?.window?.makeFirstResponder(web) }
        tv?.showToast("Home on your phone remote, or ⌘⇧H, comes back here")
        tv?.objectWillChange.send()
    }

    func closeWebPlayback() {
        if let web = webView {
            web.pauseAllMediaPlayback(completionHandler: nil)
            web.stopLoading()
            web.loadHTMLString("about:blank", baseURL: nil)
        }
        webView = nil
        closePopups()
        tv?.displayCoordinator.releasePlaybackKeepAwake()
        tv?.objectWillChange.send()
    }

    private func closePopups() {
        for popup in popups { popup.close() }
        popups.removeAll()
    }

    func makeWebView(for service: Service) -> WKWebView {
        let config = WKWebViewConfiguration()
        if let profile = tv?.profile {
            config.websiteDataStore = profile.websiteDataStore
        }
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController.addUserScript(
            WKUserScript(source: WebPlayback.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(
            WKUserScript(source: AutoPlay.script(skip: tv?.autoSkip ?? true, next: tv?.autoNext ?? true),
                         injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        if service.dpadNavigation {
            config.userContentController.addUserScript(
                WKUserScript(source: SpatialNav.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = service.userAgent
        web.uiDelegate = self
        web.navigationDelegate = self
        return web
    }

    func runWebPlayback(_ action: String, in web: WKWebView, fallback: Key) {
        Task { @MainActor [weak self, weak web] in
            guard let web else { return }
            do {
                let value = try await web.callAsyncJavaScript("return await window.__macTVPlayback(action)",
                    arguments: ["action": action], contentWorld: .page)
                guard self?.webView === web else { return }
                if value as? String == "none" { self?.sendKey(fallback, to: web) }
                else if value as? String == "unsupported" { self?.tv?.showToast("The website didn't accept this control. Try its on-screen player controls.") }
            } catch {
                if self?.webView === web { self?.sendKey(fallback, to: web) }
            }
        }
    }

    func sendKey(_ key: Key, to web: WKWebView) {
        guard let window = web.window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: key.flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: key.chars, charactersIgnoringModifiers: key.chars,
                isARepeat: false, keyCode: key.code)
            else { continue }
            window.sendEvent(event)
        }
    }

    func scrollPage(_ web: WKWebView, by dy: Double) {
        let point = tv?.pointer ?? CGPoint(x: web.bounds.midX, y: web.bounds.midY)
        let x = Int(point.x), y = Int(web.bounds.height - point.y), amount = Int(dy)
        web.evaluateJavaScript("""
            ((x, y, dy) => {
              for (let el = document.elementFromPoint(x, y); el && el !== document.body; el = el.parentElement) {
                const style = getComputedStyle(el);
                if (/(auto|scroll)/.test(style.overflowY) && el.scrollHeight > el.clientHeight) { el.scrollBy(0, dy); return; }
              }
              window.scrollBy(0, dy);
            })(\(x), \(y), \(amount))
        """)
    }

    func handleInPlayer(_ command: RemoteCommand, service: Service) {
        if tv?.playerFailure != nil { tv?.handlePlayerFailure(command); return }
        guard let web = webView else { return }
        switch command {
        case .move(let direction): sendKey(.direction(direction), to: web)
        case .select: sendKey(.enter, to: web)
        case .back:
            if !service.dpadNavigation {
                sendKey(.escape, to: web)
            } else if web.canGoBack {
                web.goBack()
            } else {
                tv?.goHome()
            }
        case .playPause:
            runWebPlayback("toggle", in: web, fallback: .space)
        case .seek(let forward):
            if service.id == "netflix" { sendKey(forward ? .right : .left, to: web) }
            else { runWebPlayback(forward ? "forward" : "backward", in: web, fallback: forward ? .right : .left) }
        case .text(let text):
            for character in text {
                sendKey(character == "\n" ? .enter : Key(code: 0, chars: String(character)), to: web)
            }
        case .deleteBackward: sendKey(.delete, to: web)
        case .pointer(let dx, let dy): tv?.movePointer(dx: dx, dy: dy)
        case .click: tv?.clickPointer()
        case .scroll(let dy): scrollPage(web, by: dy)
        case .openInBrowser:
            if let url = web.url {
                tv?.goHome()
                NSWorkspace.shared.open(url)
            }
        default: break
        }
    }

    // MARK: - Native Movies

    func playMovie(_ movie: Movie, from seconds: Double) {
        closeIINAPlayback()
        closeExternalBrowser()
        let request = UUID()
        playbackRequest = request
        currentLocalMovie = movie
        localMoviePlayer = "native"
        tv?.objectWillChange.send()
        Task { @MainActor in
            let opened: Result<PlaybackEngine, PlaybackProblem>
            var stream: JellyfinServers.Stream?
            if movie.isRemote {
                switch await JellyfinServers.shared.stream(for: movie) {
                case .success(let found):
                    stream = found
                    opened = await AVPlayback.open(found.url).map { $0 as PlaybackEngine }
                case .failure(let problem):
                    guard playbackRequest == request else { return }
                    currentLocalMovie = nil
                    tv?.showToast(problem.message)
                    tv?.objectWillChange.send()
                    return
                }
            } else if ["mkv", "webm"].contains(movie.url.pathExtension.lowercased()) {
                opened = await Task.detached(priority: .userInitiated) { MatroskaPlayback.open(movie.url) }.value
                    .map { $0 as PlaybackEngine }
            } else {
                opened = await AVPlayback.open(movie.url).map { $0 as PlaybackEngine }
            }
            guard playbackRequest == request else {
                if case .success(let engine) = opened { engine.stop() }
                return
            }
            let format = movie.isRemote ? "jellyfin" : movie.url.pathExtension.lowercased()
            switch opened {
            case .success(let engine):
                if let stream { JellyfinServers.shared.started(stream, movie: movie, at: seconds) }
                Analytics.send(.moviePlayed, ["format": format, "player": engine is AVPlayback ? "system" : "matroska",
                                              "resumed": String(seconds > 0)])
                startMovie(movie, engine: engine, from: seconds)
            case .failure:
                Analytics.send(.moviePlayed, ["format": format, "player": "external"])
                openElsewhere(movie)
            }
        }
    }

    private func startMovie(_ movie: Movie, engine: PlaybackEngine, from seconds: Double) {
        let player = MoviePlayer(movie: movie, engine: engine)
        player.onEnd = { [weak self] in self?.closeMovie() }
        player.onClose = { [weak self] in self?.closeMovie() }
        player.onFailure = { [weak self] _ in
            self?.closeMovie()
            self?.openElsewhere(movie)
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            if tv?.movies == nil { tv?.openMoviesBrowserOnly() }
            moviePlayer = player
            tv?.setMode(.movie)
        }
        tv?.displayCoordinator.holdPlaybackKeepAwake(reason: "Watching \(movie.title) in Mac TV")
        tv?.bringToFront()
        player.start(at: seconds)
        tv?.objectWillChange.send()
    }

    func closeMovie() {
        playbackRequest = UUID()
        currentLocalMovie = nil
        if let player = moviePlayer { JellyfinServers.shared.stopped(player.movie, at: player.engine.currentTime) }
        moviePlayer?.stop()
        if let path = moviePlayer?.movie.path {
            tv?.reconcileMovieBrowserPosition(for: path)
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            moviePlayer = nil
            tv?.setMode(.launcher)
        }
        tv?.displayCoordinator.releasePlaybackKeepAwake()
        tv?.objectWillChange.send()
    }

    private func openElsewhere(_ movie: Movie) {
        guard !movie.isRemote else {
            currentLocalMovie = nil
            tv?.showToast("Mac TV couldn't play \(movie.title) from \(movie.server ?? "the server").")
            tv?.objectWillChange.send()
            return
        }
        let iina = "com.colliderli.iina", vlc = "org.videolan.vlc"
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: iina) != nil,
           let screen = tv?.playbackScreen, playInIINA(movie, screen: screen) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vlc) {
            NSWorkspace.shared.open([movie.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            tv?.setLaunchedAppID(vlc)
            tv?.showToast("Playing \(movie.title) in VLC. Home comes back here.")
        } else {
            tv?.showToast("Mac TV can't play this file. IINA, free from iina.io, can.")
        }
    }

    func handleInMovie(_ command: RemoteCommand) {
        guard let player = moviePlayer else { return }
        if player.menu != nil {
            switch command {
            case .move(let direction): player.moveInMenu(direction)
            case .select: player.chooseInMenu()
            case .back: player.menu = nil; player.showControls()
            case .playPause: player.togglePlayback()
            default: break
            }
            return
        }
        switch command {
        case .select, .playPause: player.togglePlayback()
        case .move(.left): player.skip(-10)
        case .move(.right): player.skip(10)
        case .seek(let forward): player.skip(forward ? 10 : -10)
        case .move(.down): player.openMenu()
        case .move(.up): player.showControls()
        case .back: closeMovie()
        case .pointer, .click, .scroll: player.showControls()
        default: break
        }
    }

    // MARK: - IINA Playback

    @discardableResult
    func playInIINA(_ movie: Movie, subtitle: URL? = nil, position: Double? = nil, screen: NSScreen) -> Bool {
        if currentLocalMovie?.path == movie.path, let session = iinaSession, session.isRunning {
            do {
                if let subtitle { try session.loadSubtitle(subtitle) }
                try session.activate()
                return true
            } catch {
                iinaPlaybackError = error.localizedDescription
                tv?.showToast(error.localizedDescription)
                tv?.objectWillChange.send()
                return false
            }
        }
        let pos = position ?? (moviePlayer?.movie.path == movie.path ? moviePlayer?.time : nil)
        var launched: IINAPlaybackSession?
        do {
            let session = try IINAPlaybackSession()
            launched = session
            tv?.goHome()
            iinaSession = session
            currentLocalMovie = movie
            localMoviePlayer = "iina"
            tv?.setLaunchedAppID("com.colliderli.iina")
            iinaPlaybackStatus = "Opening IINA on \(screen.localizedName)…"
            session.onError = { [weak self, weak session] error in
                guard let self, let session, self.iinaSession === session else { return }
                self.iinaPlaybackError = error.localizedDescription + (session.isRunning ? "" : " Select the movie again in Files.")
                self.iinaPlaybackStatus = "IINA needs attention"
                if !session.isRunning { self.tv?.displayCoordinator.releasePlaybackKeepAwake() }
                self.tv?.showToast(error.localizedDescription)
                self.tv?.objectWillChange.send()
            }
            session.onReady = { [weak self, weak session] in
                guard let self, let session, self.iinaSession === session else { return }
                self.iinaPlaybackError = nil
                self.iinaPlaybackStatus = "IINA on \(screen.localizedName)"
                self.tv?.objectWillChange.send()
            }
            try session.launch(file: movie.url, subtitle: subtitle, position: pos, screen: screen)
            tv?.displayCoordinator.holdPlaybackKeepAwake(reason: "Watching a movie in IINA")
            tv?.objectWillChange.send()
            return true
        } catch {
            launched?.close()
            iinaSession = nil
            currentLocalMovie = nil
            iinaPlaybackError = error.localizedDescription
            tv?.showToast(error.localizedDescription)
            tv?.objectWillChange.send()
            return false
        }
    }

    func closeIINAPlayback(terminating: Bool = false) {
        let previous = iinaSession
        iinaSession = nil
        iinaPlaybackError = nil
        iinaPlaybackStatus = ""
        previous?.close(immediate: terminating)
        tv?.objectWillChange.send()
    }

    func handleIINACommand(_ command: RemoteCommand) {
        _ = iinaSession?.handle(command)
    }

    func searchIINASubtitles() -> Bool {
        guard AXIsProcessTrusted() else {
            tv?.showToast("Allow Mac TV in Accessibility settings to control IINA."); return false
        }
        guard let expected = currentLocalMovie?.path else { return false }
        Task { @MainActor [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, self.currentLocalMovie?.path == expected else { return }
                let target: NSRunningApplication?
                if let session = self.iinaSession { target = session.application }
                else { target = NSRunningApplication.runningApplications(withBundleIdentifier: "com.colliderli.iina").first }
                guard let running = target else { continue }
                running.activate(options: [])
                let element = AXUIElementCreateApplication(running.processIdentifier)
                var bar: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXMenuBarAttribute as CFString, &bar) == .success,
                      let bar else { continue }
                if self.pressIINASubtitleSearch(unsafeBitCast(bar, to: AXUIElement.self), depth: 0) { return }
            }
            self?.tv?.showToast("IINA search wasn't available. Use the phone's subtitle upload or web search.")
        }
        return true
    }

    private func pressIINASubtitleSearch(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 6 else { return false }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        let name = (title as? String ?? "").lowercased()
        if name.contains("online") && name.contains("subtitle") && (name.contains("find") || name.contains("search")) {
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in children as? [AXUIElement] ?? [] {
            if pressIINASubtitleSearch(child, depth: depth + 1) { return true }
        }
        return false
    }

    // MARK: - External Browser (Brave)

    func playInBrave(_ service: Service, url: URL) {
        closeExternalBrowser()
        webView?.pauseAllMediaPlayback(completionHandler: nil)
        webView?.stopLoading()
        webView = nil
        currentLocalMovie = nil
        tv?.playerFailure = nil
        moviePlayer?.stop()
        moviePlayer = nil
        tv?.setLaunchedAppID(nil)
        let session = BraveSession()
        externalBrowser = session
        tv?.browserFocus = 0
        externalBrowserService = service
        tv?.setMode(.player(service))
        tv?.displayCoordinator.holdPlaybackKeepAwake(reason: "Watching \(service.name) in Brave")
        openExternalBrowser(session, url: url)
        tv?.objectWillChange.send()
    }

    func retryExternalBrowser() {
        guard !externalBrowserOpening, externalBrowser != nil,
              let service = externalBrowserService, case .web(let url) = service.kind else { return }
        playInBrave(service, url: url)
    }

    func navigateExternalBrowser(service: Service, url: URL) throws {
        guard let browser = externalBrowser else { return }
        externalBrowserService = service
        try browser.navigate(to: url)
        externalBrowserError = nil
        tv?.setMode(.player(service))
        tv?.objectWillChange.send()
    }

    private func openExternalBrowser(_ session: BraveSession, url: URL) {
        let request = UUID()
        playbackRequest = request
        externalBrowserError = nil
        externalBrowserOpening = true
        tv?.objectWillChange.send()
        Task { @MainActor [weak self] in
            do {
                try await session.open(url)
                guard let self, self.playbackRequest == request, self.externalBrowser === session else {
                    try? session.close(); return
                }
                if let screen = self.tv?.playbackScreen {
                    try await session.fit(to: screen)
                }
                guard self.playbackRequest == request, self.externalBrowser === session else {
                    try? session.close(); return
                }
                try session.activate()
                self.externalBrowserOpening = false
                self.tv?.objectWillChange.send()
            } catch {
                guard let self, self.playbackRequest == request, self.externalBrowser === session else { return }
                self.externalBrowserOpening = false
                self.tv?.displayCoordinator.releasePlaybackKeepAwake()
                self.externalBrowserError = error.localizedDescription
                self.tv?.bringToFront()
                self.tv?.objectWillChange.send()
            }
        }
    }

    func activateExternalBrowser() {
        do {
            try externalBrowser?.activate()
            externalBrowserError = nil
        } catch {
            externalBrowserError = error.localizedDescription
            tv?.showToast(error.localizedDescription)
        }
        tv?.objectWillChange.send()
    }

    func closeExternalBrowser() {
        let previous = externalBrowser
        externalBrowser = nil
        externalBrowserService = nil
        externalBrowserError = nil
        externalBrowserOpening = false
        do { try previous?.close() }
        catch BraveSession.SessionError.noWindow {}
        catch BraveSession.SessionError.unavailable {}
        catch { tv?.showToast("Could not close the Mac TV Brave window. Close it manually in Brave.") }
        tv?.objectWillChange.send()
    }

    func handleExternalBrowserCommand(_ command: RemoteCommand) {
        guard let browser = externalBrowser else { return }
        do { _ = try browser.handle(command) }
        catch {
            externalBrowserError = error.localizedDescription
            tv?.showToast(error.localizedDescription)
            tv?.objectWillChange.send()
        }
    }
}

// MARK: - WKUIDelegate

extension PlaybackCoordinator: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 700), configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self
        let popupWindow = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                                   backing: .buffered, defer: false)
        popupWindow.contentView = popup
        popupWindow.isReleasedWhenClosed = false
        popupWindow.level = .floating
        if let frame = tv?.window?.frame {
            popupWindow.setFrameOrigin(NSPoint(x: frame.midX - 260, y: frame.midY - 350))
        }
        popupWindow.makeKeyAndOrderFront(nil)
        popups.append(popupWindow)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let popupWindow = popups.first(where: { $0.contentView === webView }) else { return }
        popupWindow.close()
        popups.removeAll { $0 === popupWindow }
    }
}

// MARK: - WKNavigationDelegate

extension PlaybackCoordinator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tv?.recordPlayerFailure(webView, error: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tv?.recordPlayerFailure(webView, error: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { tv?.recordPlayerFailure(webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView {
            tv?.playerFailure = nil
            tv?.objectWillChange.send()
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame ?? true, let host = navigationAction.request.url?.host() else { return .allow }
        let signingIn = host == "accounts.google.com" || host.hasSuffix(".accounts.google.com")
        var usual = UserAgent.safari
        if case .player(let service) = tv?.mode { usual = service.userAgent }
        let wanted = signingIn ? UserAgent.googleSignIn : usual
        if webView.customUserAgent != wanted { webView.customUserAgent = wanted }
        return .allow
    }
}
