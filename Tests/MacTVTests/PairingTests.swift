import Foundation
import Testing
@testable import MacTV

@Suite struct PairingTests {
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    @Test func individualTokensPersistAndRevoke() throws {
        try withFolder { folder in
            let store = PairingStore(folder: folder)
            let first = try store.issue(name: "First", guest: false)
            let second = try store.issue(name: "Second", guest: false)
            #expect(first.count == 64 && second.count == 64 && first != second)
            let saved = try String(contentsOf: folder.appendingPathComponent("paired-devices.json"), encoding: .utf8)
            #expect(!saved.contains(first) && !saved.contains(second))
            let reloaded = PairingStore(folder: folder)
            let id = try #require(reloaded.authenticate(first)?.id)
            #expect(reloaded.authenticate(second)?.name == "Second")
            try reloaded.revoke(id: id)
            #expect(reloaded.authenticate(first) == nil)
            #expect(reloaded.authenticate(second) != nil)
            try reloaded.revokeAll()
            #expect(PairingStore(folder: folder).authenticate(second) == nil)
        }
    }

    @Test func guestExpiresAndPinIsNotAToken() throws {
        try withFolder { folder in
            var date = Date(timeIntervalSince1970: 1_000)
            let store = PairingStore(folder: folder, now: { date })
            let token = try store.issue(name: "Guest", guest: true)
            #expect(store.authenticate(token)?.isGuest == true)
            #expect(store.authenticate("123456") == nil)
            date = date.addingTimeInterval(24 * 60 * 60)
            #expect(store.authenticate(token) == nil)
        }
    }

    @Test func invalidLengthsNeverParse() {
        for length in ["-1", "1048577", "abc"] {
            #expect(HTTPRequest.parse(Data("POST /pair HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n".utf8)) == nil)
        }
    }
}

@Suite @MainActor struct PairingServerTests {
    @Test func legacyCodeCannotReenrollAfterRevokeAll() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        let suiteName = "MacTVTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName); try? FileManager.default.removeItem(at: folder) }
        let clock = Date(timeIntervalSince1970: 1000)
        let legacy = RemoteServer.pairingCode(now: clock) == "246810" ? "246811" : "246810"
        defaults.set(legacy, forKey: "pairingCode")
        let server = RemoteServer(token: "unused", onCommand: { _ in }, state: { [:] }, icon: { _ in nil }, routes: { _ in nil },
                                  pairing: PairingStore(folder: folder, now: { clock }), defaults: defaults, now: { clock })
        func request(_ path: String, body: [String: Any], token: String? = nil) throws -> HTTPResponse {
            let data = try JSONSerialization.data(withJSONObject: body)
            return server.respond(to: HTTPRequest(method: "POST", path: path, query: [:],
                                                   headers: token.map { ["x-couch-key": $0] } ?? [:], body: data))
        }
        let paired = try request("/pair", body: ["code": legacy])
        #expect(paired.status == "200 OK")
        let object = try #require(try JSONSerialization.jsonObject(with: paired.body) as? [String: Any])
        let token = try #require(object["token"] as? String)
        #expect(try request("/devices/revoke-all", body: [:], token: token).status == "200 OK")
        #expect(try request("/pair", body: ["code": legacy]).status == "401 Unauthorized")
    }

    @Test func pairingCodeRotatesAfterFiveMinutes() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let first = RemoteServer.pairingCode(now: start)
        #expect(first.count == 6)
        #expect(RemoteServer.pairingCode(now: start.addingTimeInterval(299)) == first)
        #expect(RemoteServer.pairingCode(now: start.addingTimeInterval(300)) != first)
    }
    @Test func guestsCannotBrowseFilesOrReadSelectedMovie() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        let suite = "MacTVTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let store = PairingStore(folder: folder)
        let token = try store.issue(name: "Guest", guest: true)
        var routed = false
        let server = RemoteServer(token: "unused", onCommand: { _ in }, state: { ["currentLocalMovie": ["title": "Private"], "mode": "launcher"] }, icon: { _ in nil }, routes: { _ in routed = true; return nil }, pairing: store, defaults: defaults)
        for path in ["/files", "/files/roots", "/files/play", "/files/subtitle-upload"] {
            let response = server.respond(to: HTTPRequest(method: "GET", path: path, query: [:], headers: ["x-couch-key": token], body: Data()))
            #expect(response.status == "403 Forbidden")
        }
        #expect(!routed)
        let response = server.respond(to: HTTPRequest(method: "GET", path: "/state", query: [:], headers: ["x-couch-key": token], body: Data()))
        let state = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(state["currentLocalMovie"] == nil)
    }

}
