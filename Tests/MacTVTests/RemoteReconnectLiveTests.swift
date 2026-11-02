import AppKit
import Foundation
import Testing
import WebKit
@testable import MacTV

/// The whole move, in WebKit (what iPhone browsers use) against a real server on this Mac: a remote
/// opened at one address finds the Mac at its .local name and moves there, still paired.
/// It needs a working network and Bonjour, which build machines may lack, so it runs only with
/// MACTV_LIVE_REMOTE_TEST=1. It uses its own server, port and pairings; Mac TV isn't touched.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACTV_LIVE_REMOTE_TEST"] == "1")) @MainActor
struct RemoteReconnectLiveTests {
    @Test func aRemoteMovesToTheMacsNameStillPaired() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        let suite = "MacTVTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let name = try #require(LAN.bonjourName())
        let port: UInt16 = 28765
        let nameOrigin = "http://\(name):\(port)", loopOrigin = "http://127.0.0.1:\(port)"

        let server = RemoteServer(token: "unused", onCommand: { _ in },
                                  state: { ["addresses": [nameOrigin, loopOrigin], "apps": [], "mode": "launcher"] },
                                  icon: { _ in nil }, routes: { _ in nil },
                                  pairing: PairingStore(folder: folder), defaults: defaults,
                                  ownOrigins: { [nameOrigin, loopOrigin] })
        var ready = false
        server.start(ports: [port]) { _ in ready = true }
        defer { server.stop() }
        for _ in 0..<50 where !ready { try await Task.sleep(for: .milliseconds(100)) }
        try #require(ready)

        let code = RemoteServer.pairingCode()
        let paired = server.respond(to: HTTPRequest(method: "POST", path: "/pair", query: [:], headers: [:],
                                                    body: try JSONSerialization.data(withJSONObject: ["code": code, "name": "Test"])))
        let token = try #require((try JSONSerialization.jsonObject(with: paired.body) as? [String: Any])?["token"] as? String)

        // The remote, open at the loopback address with its key and the Mac's addresses saved.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        web.load(URLRequest(url: URL(string: loopOrigin + "/")!))
        try await waitFor { await web.isLoaded(at: loopOrigin) }
        _ = try await web.callAsyncJavaScript("""
            localStorage.setItem('mactvKey', key0);
            localStorage.setItem('mactvAddresses', JSON.stringify([loop, nameOrigin]));
            key = key0;
            return await moveToAnotherAddress();
            """, arguments: ["key0": token, "loop": loopOrigin, "nameOrigin": nameOrigin], contentWorld: .page)

        // It lands on the name, keeps the key, clears it from the address bar and reads the state.
        try await waitFor { await web.isLoaded(at: nameOrigin) }
        let stored = try await web.evaluateJavaScript("localStorage.getItem('mactvKey')") as? String
        #expect(stored == token)
        #expect(web.url?.fragment == nil)
        let reachable = try await web.callAsyncJavaScript("return await refresh();", arguments: [:], contentWorld: .page) as? Bool
        #expect(reachable == true)
    }

    private func waitFor(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("Timed out waiting")
    }
}

private extension WKWebView {
    /// The page at `origin` has finished loading.
    func isLoaded(at origin: String) async -> Bool {
        guard url?.absoluteString.hasPrefix(origin) == true, !isLoading else { return false }
        return (try? await evaluateJavaScript("document.readyState") as? String) == "complete"
    }
}
