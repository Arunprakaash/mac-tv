import AppKit
import WebKit

/// `MacTV --selftest-drm` prints which DRM systems the embedded web view offers, then quits.
/// Streaming sites need FairPlay (com.apple.fps) here for anything above SD.
@MainActor
enum DRMSelfTest {
    private static var webView: WKWebView?

    static func start() {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        web.customUserAgent = UserAgent.safari
        web.loadHTMLString("<!doctype html><title>drm</title>", baseURL: URL(string: "https://example.com/")!)
        webView = web

        Task {
            try? await Task.sleep(for: .seconds(2))
            do {
                let result = try await web.callAsyncJavaScript(script, contentWorld: .page)
                print(result as? String ?? "no result")
            } catch {
                print("DRM self-test failed: \(error)")
            }
            exit(0)
        }
    }

    private static let script = #"""
    const out = {
      secureContext: window.isSecureContext,
      mediaSource: typeof MediaSource !== 'undefined',
      legacyWebKitMediaKeys: typeof WebKitMediaKeys !== 'undefined',
    };
    if (out.legacyWebKitMediaKeys) out.legacyFairPlay = WebKitMediaKeys.isTypeSupported('com.apple.fps.1_0', 'video/mp4');
    const configs = [{
      initDataTypes: ['sinf', 'skd', 'cenc'],
      videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.640028"' }],
      audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }],
    }];
    for (const system of ['com.apple.fps', 'com.apple.fps.1_0', 'com.widevine.alpha', 'com.microsoft.playready', 'org.w3.clearkey']) {
      try { await navigator.requestMediaKeySystemAccess(system, configs); out[system] = 'supported'; }
      catch (e) { out[system] = 'no (' + e.name + ')'; }
    }
    if (out.mediaSource) out.hevc = MediaSource.isTypeSupported('video/mp4; codecs="hvc1.2.4.L153.B0"');
    return JSON.stringify(out, null, 2);
    """#
}

/// `MacTV --export-remote <file.png> [sheet]` renders the phone remote, connected to the
/// running Mac TV for real data, and quits. `sheet` opens "apps", "add" or "controls" first.
@MainActor
enum RemoteSnapshot {
    private static var webView: WKWebView?

    static func start(to file: URL, sheet: String?) {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 412, height: 860))
        web.customUserAgent = "Mozilla/5.0 (Linux; Android 16; Pixel) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Mobile Safari/537.36"
        let code = RemoteServer.pairingCode()
        web.loadHTMLString(RemotePage.html, baseURL: URL(string: "http://127.0.0.1:8765/?k=\(code)")!)
        webView = web

        Task {
            try? await Task.sleep(for: .seconds(2))
            let open: String
            switch sheet {
            case "apps": open = "document.querySelector('#open-apps').click();"
            case "add": open = "document.querySelector('#open-apps').click(); document.querySelector('.app.add')?.click();"
            case "controls": open = "document.querySelector('#open-power').click();"
            default: open = ""
            }
            _ = try? await web.evaluateJavaScript(open + "'ok'")
            try? await Task.sleep(for: .seconds(1.5))
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = NSNumber(value: 412 * 2)
            if let image = try? await web.takeSnapshot(configuration: config),
               let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: file)
                print("Wrote \(file.path)")
            } else {
                print("Remote snapshot failed")
            }
            exit(0)
        }
    }
}
