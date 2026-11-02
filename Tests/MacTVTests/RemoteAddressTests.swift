import Foundation
import Testing
@testable import MacTV

@Suite @MainActor
struct RemoteAddressTests {
    private func server(origins: [String]) -> RemoteServer {
        RemoteServer(token: "unused", onCommand: { _ in }, state: { [:] }, icon: { _ in nil }, routes: { _ in nil },
                     ownOrigins: { origins })
    }

    private func request(_ method: String, _ path: String, origin: String?) -> HTTPRequest {
        HTTPRequest(method: method, path: path, query: [:], headers: origin.map { ["origin": $0] } ?? [:], body: Data())
    }

    private func header(_ name: String, in response: HTTPResponse) -> String? {
        response.headers.first { $0.0 == name }?.1
    }

    @Test func onlyTheMacsOwnAddressesMayAskAcross() {
        let name = "http://arun.local:8765"
        let remote = server(origins: [name, "http://192.168.1.5:8765"])

        let allowed = remote.respond(to: request("OPTIONS", "/state", origin: name))
        #expect(allowed.status == "204 No Content")
        #expect(header("Access-Control-Allow-Origin", in: allowed) == name)
        #expect(header("Access-Control-Allow-Headers", in: allowed)?.contains("X-Couch-Key") == true)

        // Browsers lowercase host names in an origin.
        let mixedCase = server(origins: ["http://MacBook-Pro-2.local:8765"])
        let lowered = mixedCase.respond(to: request("OPTIONS", "/state", origin: "http://macbook-pro-2.local:8765"))
        #expect(lowered.status == "204 No Content")
        #expect(header("Access-Control-Allow-Origin", in: lowered) == "http://macbook-pro-2.local:8765")

        let foreign = remote.respond(to: request("OPTIONS", "/state", origin: "http://evil.example"))
        #expect(foreign.status == "403 Forbidden")
        #expect(header("Access-Control-Allow-Origin", in: foreign) == nil)

        // Ordinary answers carry the header only for the Mac's own addresses.
        #expect(header("Access-Control-Allow-Origin", in: remote.respond(to: request("GET", "/", origin: name))) == name)
        #expect(header("Access-Control-Allow-Origin", in: remote.respond(to: request("GET", "/", origin: "http://evil.example"))) == nil)
        #expect(header("Access-Control-Allow-Origin", in: remote.respond(to: request("GET", "/", origin: nil))) == nil)
    }

    @Test func extraHeadersAreWrittenOut() {
        let response = HTTPResponse(status: "204 No Content", headers: [("Vary", "Origin")])
        let text = String(decoding: response.serialized(keepAlive: false), as: UTF8.self)
        #expect(text.contains("\r\nVary: Origin\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func theWifiLinkUsesTheMacsNameWithTheIPToType() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
        let tv = TVController(library: AppLibrary(folder: folder))
        tv.remotePort = 18765
        // Build machines may have no network.
        guard let ip = LAN.ipv4(), let name = LAN.bonjourName() else { return }
        let wifi = try #require(tv.remoteLinks.first { $0.label == "Same Wi-Fi" })
        #expect(wifi.address == "http://\(name):18765")
        #expect(wifi.fallback == "\(ip):18765")
        #expect(tv.remoteCoordinator.origins.contains("http://\(name):18765"))
        #expect(tv.remoteCoordinator.origins.contains("http://\(ip):18765"))
        #expect(name.hasSuffix(".local"))
        #expect(name == name.lowercased())
    }
}

@Suite struct RemoteAddressParsingTests {
    @Test func preflightRequestsAreParsed() throws {
        let raw = "OPTIONS /state HTTP/1.1\r\nHost: 192.168.1.5:8765\r\nOrigin: http://arun.local:8765\r\n\r\n"
        guard case .complete(let request, _) = HTTPRequest.parseResult(Data(raw.utf8)) else {
            Issue.record("An OPTIONS preflight should parse"); return
        }
        #expect(request.method == "OPTIONS")
        #expect(request.headers["origin"] == "http://arun.local:8765")
        guard case .invalid = HTTPRequest.parseResult(Data("DELETE /state HTTP/1.1\r\n\r\n".utf8)) else {
            Issue.record("Other methods stay rejected"); return
        }
    }
}
