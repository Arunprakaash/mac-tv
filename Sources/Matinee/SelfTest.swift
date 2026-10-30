import AppKit
import WebKit

/// `Matinee --selftest-drm` prints which DRM systems the embedded web view offers, then quits.
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
