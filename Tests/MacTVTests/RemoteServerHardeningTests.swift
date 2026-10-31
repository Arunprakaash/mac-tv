import Foundation
import Darwin
import Network
import Testing
@testable import MacTV

@Suite @MainActor struct RemoteServerHardeningTests {
    @Test func rejectsMalformedAndOversizedRequests() {
        let malformed = [
            "POST /pair HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n",
            "POST /pair HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST /pair HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n",
            "GET http://example.com/ HTTP/1.1\r\n\r\n",
            "GET / HTTP/1.1\r\nMalformed\r\n\r\n"
        ]
        for input in malformed {
            if case .invalid = HTTPRequest.parseResult(Data(input.utf8)) {} else { Issue.record("Accepted malformed request") }
        }
        if case .invalid = HTTPRequest.parseResult(Data(repeating: 65, count: 16385)) {} else { Issue.record("Accepted oversized header") }
        if case .incomplete = HTTPRequest.parseResult(Data("POST /pair HTTP/1.1\r\nContent-Length: 2\r\n\r\n{".utf8)) {} else { Issue.record("Incomplete body was rejected") }
    }

    @Test func guestsAreRestrictedToPlaybackCommands() throws {
        var template = Array("/tmp/mactv-pairtest.XXXXXXXX".utf8CString)
        let name = try #require(mkdtemp(&template))
        let path = String(cString: name)
        let folder = URL(fileURLWithPath: path)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PairingStore(folder: folder)
        let guest = try store.issue(name: "Guest", guest: true)
        let owner = try store.issue(name: "Owner", guest: false)
        var commands = 0, routed = 0
        let server = RemoteServer(token: "", onCommand: { _ in commands += 1 },
                                  state: { ["currentLocalMovie": ["title": "Private"], "current": ["id": "movies", "name": "Private"]] },
                                  icon: { _ in nil }, routes: { _ in routed += 1; return .json(["ok": true]) }, pairing: store)
        func request(_ path: String, token: String, action: String = "") -> HTTPResponse {
            let body = try! JSONSerialization.data(withJSONObject: ["a": action])
            return server.respond(to: HTTPRequest(method: "POST", path: path, query: [:], headers: ["x-couch-key": token], body: body))
        }
        #expect(request("/cmd", token: guest, action: "playpause").status == "200 OK")
        for action in ["sleep", "screenoff", "launch", "setting", "controlcenter"] {
            #expect(request("/cmd", token: guest, action: action).status != "200 OK")
        }
        #expect(request("/apps/restore", token: guest).status == "403 Forbidden")
        #expect(request("/apps/restore", token: owner).status == "200 OK")
        #expect(commands == 1 && routed == 1)
        let stateResponse = server.respond(to: HTTPRequest(method: "GET", path: "/state", query: [:], headers: ["x-couch-key": guest], body: Data()))
        let state = try #require(try JSONSerialization.jsonObject(with: stateResponse.body) as? [String: Any])
        #expect(state["currentLocalMovie"] == nil)
        #expect((state["current"] as? [String: String])?["name"] == "Movie")
        server.stop()
        server.stop()
        #expect(server.activeConnectionCount == 0)
    }
    @Test func pairingCodeDeterminesRoleRegardlessOfClientFlag() throws {
        var template = Array("/tmp/mactv-codes.XXXXXXXX".utf8CString)
        let name = try #require(mkdtemp(&template))
        let folder = URL(fileURLWithPath: String(cString: name))
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PairingStore(folder: folder)
        let server = RemoteServer(token: "", onCommand: { _ in }, state: { [:] },
                                  icon: { _ in nil }, routes: { _ in nil }, pairing: store)
        let ownerCode = RemoteServer.pairingCode()
        let guestCode = RemoteServer.guestPairingCode()
        #expect(ownerCode != guestCode)
        func pair(_ code: String, claimedGuest: Bool) throws -> String {
            let body = try JSONSerialization.data(withJSONObject: ["code": code, "guest": claimedGuest])
            let response = server.respond(to: HTTPRequest(method: "POST", path: "/pair", query: [:], headers: [:], body: body))
            #expect(response.status == "200 OK")
            let data = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            return try #require(data["token"] as? String)
        }
        let guestToken = try pair(guestCode, claimedGuest: false)
        #expect(store.authenticate(guestToken)?.isGuest == true)
        let ownerToken = try pair(ownerCode, claimedGuest: true)
        #expect(store.authenticate(ownerToken)?.isGuest == false)
        let guestRequest = HTTPRequest(method: "POST", path: "/apps/restore", query: [:],
                                       headers: ["x-couch-key": guestToken], body: Data())
        #expect(server.respond(to: guestRequest).status == "403 Forbidden")
    }

    @Test func guestHandlerGatesContextAndTrustedCommandsStayIndependent() throws {
        var template = Array("/tmp/mactv-guest.XXXXXXXX".utf8CString)
        let name = try #require(mkdtemp(&template))
        let folder = URL(fileURLWithPath: String(cString: name))
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PairingStore(folder: folder)
        let guest = try store.issue(name: "Guest", guest: true)
        let owner = try store.issue(name: "Owner", guest: false)
        var ownerCalls = 0, guestCalls = 0
        let server = RemoteServer(token: "", onCommand: { _ in ownerCalls += 1 }, state: { [:] },
                                  icon: { _ in nil }, routes: { _ in nil }, pairing: store,
                                  onGuestCommand: { _ in guestCalls += 1; return false })
        func command(_ token: String, _ action: String) -> HTTPResponse {
            let body = try! JSONSerialization.data(withJSONObject: ["a": action])
            return server.respond(to: HTTPRequest(method: "POST", path: "/cmd", query: [:],
                                                   headers: ["x-couch-key": token], body: body))
        }
        #expect(command(guest, "up").status == "403 Forbidden")
        #expect(guestCalls == 1 && ownerCalls == 0)
        #expect(command(owner, "up").status == "200 OK")
        #expect(guestCalls == 1 && ownerCalls == 1)
        #expect(command(guest, "sleep").status == "403 Forbidden")
        #expect(guestCalls == 1)

        let fallback = RemoteServer(token: "", onCommand: { _ in ownerCalls += 1 }, state: { [:] },
                                    icon: { _ in nil }, routes: { _ in nil }, pairing: store)
        let body = try JSONSerialization.data(withJSONObject: ["a": "up"])
        #expect(fallback.respond(to: HTTPRequest(method: "POST", path: "/cmd", query: [:],
                                                  headers: ["x-couch-key": guest], body: body)).status == "403 Forbidden")
    }

    @Test func listenerLimitsIdleClientsAndStops() async throws {
        let server = RemoteServer(token: "", onCommand: { _ in }, state: { [:] }, icon: { _ in nil }, routes: { _ in nil },
                                  limits: .init(maxConnections: 1, idleSeconds: 0.25, headerSeconds: 1, bodySeconds: 1))
        defer { server.stop() }
        var chosen: UInt16?
        let start = UInt16.random(in: 20000...40000)
        server.start(ports: Array(start..<(start + 20))) { chosen = $0 }
        for _ in 0..<100 where chosen == nil { try await Task.sleep(for: .milliseconds(20)) }
        let port = try #require(chosen)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .main)
        defer { connection.cancel() }
        for _ in 0..<100 where server.activeConnectionCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(server.activeConnectionCount == 1)
        for _ in 0..<100 where server.activeConnectionCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(server.activeConnectionCount == 0)
        server.stop()
        #expect(server.activeConnectionCount == 0)
    }

}
