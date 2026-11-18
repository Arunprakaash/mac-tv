import AppKit
import SwiftUI
import WebKit

struct PlayerFailure: Equatable {
    let message: String
    var selected = 0
}

@MainActor
final class PlaybackDiagnostics: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var result = "Checking WebKit capabilities…"
    private var web: WKWebView?
    let displays: String = NSScreen.screens.map { screen in
        let mode = CGDisplayCopyDisplayMode(screen.displayID)
        return "\(screen.localizedName): \(mode?.pixelWidth ?? 0) × \(mode?.pixelHeight ?? 0), \(Int(mode?.refreshRate ?? 0)) Hz"
    }.joined(separator: "\n")

    func start() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        web = view
        view.navigationDelegate = self
        view.customUserAgent = UserAgent.safari
        view.loadHTMLString("<!doctype html><title>Playback check</title>", baseURL: URL(string: "https://example.com/"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            do {
                let value = try await webView.callAsyncJavaScript(DRMSelfTest.script, contentWorld: .page)
                self?.result = value as? String ?? "No capability report available."
            } catch { self?.result = "Capability check failed: \(error.localizedDescription)" }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        result = "Capability check could not start: \(error.localizedDescription)"
    }
}

extension TVController {
    func openPlaybackCheck() {
        let check = PlaybackDiagnostics()
        playbackCheck = check
        check.start()
    }
    func recordPlayerFailure(_ web: WKWebView, error: Error? = nil) {
        guard web === webView, case .player = mode else { return }
        if let error, (error as NSError).code == NSURLErrorCancelled { return }
        if let error { Log.playback.failure("Streaming page didn't load", error) }
        else { Log.playback.error("Streaming page stopped responding") }
        playerFailure = PlayerFailure(message: error == nil
            ? "The streaming page stopped responding."
            : "The streaming page couldn't load. Check the connection, then try again.")
    }
    func handlePlayerFailure(_ command: RemoteCommand) {
        guard var panel = playerFailure else { return }
        switch command {
        case .move(.left), .move(.up): panel.selected = max(0, panel.selected - 1)
        case .move(.right), .move(.down): panel.selected = min(2, panel.selected + 1)
        case .select: performPlayerRecovery(panel.selected); return
        case .back: goHome(); return
        default: return
        }
        playerFailure = panel
    }
    func performPlayerRecovery(_ action: Int) {
        switch action {
        case 0:
            playerFailure = nil
            webView?.reload()
        case 1:
            guard case .player(let service) = mode else { return }
            let url: URL?
            if let current = webView?.url, ["http", "https"].contains(current.scheme ?? "") { url = current }
            else if case .web(let original) = service.kind { url = original }
            else { url = nil }
            guard let url, let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
                showToast("Safari isn't available. Retry or return Home."); return
            }
            NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
            goHome()
        default: goHome()
        }
    }
}

struct PlaybackFailureView: View {
    @ObservedObject var tv: TVController
    var body: some View {
        VStack(spacing: 28) {
            Text("Playback needs attention").font(.system(size: 42, weight: .bold))
            Text(tv.playerFailure?.message ?? "").font(.system(size: 26)).multilineTextAlignment(.center)
            HStack(spacing: 24) {
                ForEach(Array(["Retry", "Open in Safari", "Home"].enumerated()), id: \.offset) { index, label in
                    Button(label) { tv.performPlayerRecovery(index) }
                        .buttonStyle(.plain).font(.system(size: 26, weight: .semibold)).padding(24)
                        .foregroundStyle(tv.playerFailure?.selected == index ? .black : .white)
                        .background(tv.playerFailure?.selected == index ? .white : .white.opacity(0.12), in: Capsule())
                }
            }
            InputHintsBar(tv: tv, set: .chooser)
        }
        .padding(60).frame(width: 1280)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.8))
    }
}

struct PlaybackCheckSheet: View {
    @ObservedObject var tv: TVController
    var body: some View {
        if let check = tv.playbackCheck {
            PlaybackCheckContent(tv: tv, check: check)
        }
    }
}

private struct PlaybackCheckContent: View {
    @ObservedObject var tv: TVController
    @ObservedObject var check: PlaybackDiagnostics
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Playback check").font(.tv(.title3, emphasized: true))
            Text("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)").font(.tv(.caption1))
            Text(check.displays).font(.tv(.caption1))
            Text(check.result).font(.system(size: 19, design: .monospaced)).textSelection(.enabled)
            Text("These checks detect capabilities. Actual resolution, HDR and HDCP are not verified.")
                .font(.tv(.caption1, emphasized: true))
            Text("Netflix: check your plan, Safari compatibility and the display/cable requirements. Other services may limit embedded players. If a title fails, try Safari. Sign-in and subscription checks remain with each service.")
                .font(.tv(.caption1)).foregroundStyle(.white.opacity(0.75))
            InputHintsBar(tv: tv, set: .info)
        }.padding(50).frame(width: 1380)
            .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
            .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
