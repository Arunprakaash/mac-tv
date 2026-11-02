import Foundation
import Network

/// A tiny HTTP server on the LAN: serves the phone remote page and accepts its commands.
/// Everything runs on the main queue.
final class RemoteServer {
    typealias CommandHandler = @MainActor (RemoteCommand) -> Void
    typealias GuestCommandHandler = @MainActor (RemoteCommand) -> Bool
    typealias StateProvider = @MainActor () -> [String: Any]
    typealias IconProvider = @MainActor (String) -> Data?
    typealias Routes = @MainActor (HTTPRequest) -> HTTPResponse?

    private let pairing: PairingStore
    private var legacyCode: String?
    private let legacyUntil: Date
    private let now: () -> Date
    private let onCommand: CommandHandler
    private let onGuestCommand: GuestCommandHandler?
    private let state: StateProvider
    private let icon: IconProvider
    private let routes: Routes
    private var listener: NWListener?
    private var failedAttempts: [Date] = []
    struct Limits {
        var maxConnections = 32
        var idleSeconds: TimeInterval = 15
        var headerSeconds: TimeInterval = 15
        var bodySeconds: TimeInterval = 30
    }
    private final class Client {
        let connection: NWConnection
        var timer: DispatchWorkItem?
        var requestStarted = Date()
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private let limits: Limits
    private var clients: [ObjectIdentifier: Client] = [:]
    private var stopped = false
    var activeConnectionCount: Int { clients.count }

    init(token: String, onCommand: @escaping CommandHandler, state: @escaping StateProvider,
         icon: @escaping IconProvider, routes: @escaping Routes,
         pairing: PairingStore = PairingStore(), defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init, limits: Limits = Limits(),
         onGuestCommand: GuestCommandHandler? = nil) {
        self.limits = limits
        self.pairing = pairing
        self.now = now
        self.legacyCode = defaults.string(forKey: "pairingCode")
        self.legacyUntil = now().addingTimeInterval(300)
        defaults.removeObject(forKey: "pairingCode")
        self.onCommand = onCommand
        self.onGuestCommand = onGuestCommand
        self.state = state
        self.icon = icon
        self.routes = routes
    }

    /// A new code is generated after five minutes, and is never accepted as a device token.
    private static var currentCode = ""
    private static var currentGuestCode = ""
    private static var codeExpires = Date.distantPast
    static func pairingCode(now: Date = Date()) -> String {
        if now >= codeExpires {
            var next: String
            repeat { next = String(format: "%06d", Int.random(in: 0...999_999)) } while next == currentCode || next == currentGuestCode
            var guest: String
            repeat { guest = String(format: "%06d", Int.random(in: 0...999_999)) }
            while guest == next || guest == currentGuestCode || guest == currentCode
            currentCode = next
            currentGuestCode = guest
            codeExpires = now.addingTimeInterval(300)
        }
        return currentCode
    }

    /// A separate capability: presenting this code can only create a guest device.
    static func guestPairingCode(now: Date = Date()) -> String {
        _ = pairingCode(now: now)
        return currentGuestCode
    }

    /// Listens on the first free port in `ports`.
    func start(ports: [UInt16], onReady: @escaping @MainActor (UInt16) -> Void) {
        guard !stopped else { return }
        guard let port = ports.first, let nwPort = NWEndpoint.Port(rawValue: port) else {
            NSLog("Mac TV: no free port for the phone remote")
            return
        }
        let tryNext = { [weak self] in self?.start(ports: Array(ports.dropFirst()), onReady: onReady) }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    guard self?.stopped == false else { listener?.cancel(); return }
                    MainActor.assumeIsolated { onReady(port) }
                case .failed:
                    listener?.cancel()
                    guard self?.stopped == false else { return }
                    tryNext()
                default: break
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            tryNext()
        }
    }

    /// Call on the listener queue (main) during app shutdown.
    func stop() {
        stopped = true
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        let active = Array(clients.values)
        clients.removeAll()
        for client in active { client.timer?.cancel(); client.connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, RemotePeer.isPrivate(connection.endpoint), clients.count < limits.maxConnections else { connection.cancel(); return }
        let client = Client(connection)
        clients[ObjectIdentifier(connection)] = client
        connection.start(queue: .main)
        read(client, buffer: Data())
    }

    private func discard(_ client: Client) {
        client.timer?.cancel()
        clients.removeValue(forKey: ObjectIdentifier(client.connection))
        client.connection.cancel()
    }

    private func armCloseDeadline(_ client: Client) {
        client.timer?.cancel()
        let timer = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client else { return }
            self.discard(client)
        }
        client.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + limits.idleSeconds, execute: timer)
    }

    private func read(_ client: Client, buffer: Data) {
        guard !stopped, clients[ObjectIdentifier(client.connection)] != nil else { return }
        client.timer?.cancel()
        let hasHeader = buffer.range(of: Data("\r\n\r\n".utf8)) != nil
        let total = hasHeader ? limits.bodySeconds : limits.headerSeconds
        let remaining = max(0, total - Date().timeIntervalSince(client.requestStarted))
        let timer = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client else { return }
            self.discard(client)
        }
        client.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + min(limits.idleSeconds, remaining), execute: timer)
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client, self.clients[ObjectIdentifier(client.connection)] != nil else { return }
            client.timer?.cancel()
            var buffer = buffer
            if let data { buffer.append(data) }
            while true {
                switch HTTPRequest.parseResult(buffer) {
                case .invalid(let status):
                    let response = HTTPResponse.json(["error": "Invalid HTTP request"], status: status)
                    self.armCloseDeadline(client)
                    client.connection.send(content: response.serialized(keepAlive: false), completion: .contentProcessed { [weak self, weak client] _ in
                        if let self, let client { self.discard(client) }
                    })
                    return
                case .incomplete:
                    if isComplete || error != nil { self.discard(client) }
                    else { self.read(client, buffer: buffer) }
                    return
                case .complete(let request, let consumed):
                    buffer = Data(buffer.dropFirst(consumed))
                    client.requestStarted = Date()
                    let response = MainActor.assumeIsolated { self.respond(to: request) }
                    // One outstanding request per connection limits queued responses.
                    // Close after a pipelined request; ordinary browser keep-alive remains supported.
                    let keepAlive = request.keepAlive && buffer.isEmpty
                    self.armCloseDeadline(client)
                    let remaining = buffer
                    client.connection.send(content: response.serialized(keepAlive: keepAlive), completion: .contentProcessed { [weak self, weak client] sendError in
                        guard let self, let client else { return }
                        if !keepAlive || sendError != nil { self.discard(client) }
                        else { self.read(client, buffer: remaining) }
                    })
                    return
                }
            }
        }
    }

    @MainActor
    func respond(to request: HTTPRequest) -> HTTPResponse {
        if request.method == "GET", request.path == "/" {
            return HTTPResponse(contentType: "text/html; charset=utf-8", body: Data(RemotePage.html.utf8))
        }
        if request.method == "GET", request.path == "/appicon.png",
           let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"), let png = try? Data(contentsOf: url) {
            return HTTPResponse(contentType: "image/png", body: png)
        }
        if request.method == "GET", request.path == "/manifest.webmanifest" {
            let manifest: [String: Any] = [
                "name": "Mac TV Remote", "short_name": "Mac TV", "display": "standalone",
                "background_color": "#0a0b0e", "theme_color": "#0a0b0e", "start_url": "/",
                "icons": [["src": "/appicon.png", "sizes": "1024x1024", "type": "image/png"]],
            ]
            var response = HTTPResponse.json(manifest)
            response.contentType = "application/manifest+json"
            return response
        }
        // App icons are public artwork; the phone shows them before pairing too.
        if request.method == "GET", request.path.hasPrefix("/icon/") {
            guard let png = icon(String(request.path.dropFirst("/icon/".count))) else {
                return .json(["error": "No icon"], status: "404 Not Found")
            }
            return HTTPResponse(contentType: "image/png", body: png)
        }

        if request.method == "POST", request.path == "/pair" {
            failedAttempts.removeAll { now().timeIntervalSince($0) >= 60 }
            guard failedAttempts.count < 20 else {
                return .json(["error": "Too many wrong codes. Try again in a minute."], status: "429 Too Many Requests")
            }
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let code = object["code"] as? String else {
                failedAttempts.append(now())
                return .json(["error": "Wrong or expired pairing code"], status: "401 Unauthorized")
            }
            let timestamp = now()
            let ownerCode = Self.pairingCode(now: timestamp)
            let guestCode = Self.guestPairingCode(now: timestamp)
            let guest: Bool
            if code == guestCode {
                guest = true
            } else if code == ownerCode || (timestamp < legacyUntil && code == legacyCode) {
                guest = false
            } else {
                failedAttempts.append(timestamp)
                return .json(["error": "Wrong or expired pairing code"], status: "401 Unauthorized")
            }
            do {
                let token = try pairing.issue(name: object["name"] as? String ?? "Phone", guest: guest)
                return .json(["token": token])
            } catch { return .json(["error": "Could not save paired device"], status: "500 Internal Server Error") }
        }
        guard let device = pairing.authenticate(request.headers["x-couch-key"]) else {
            return .json(["error": "Pair with the TV first"], status: "401 Unauthorized")
        }
        if device.isGuest && !(request.method == "GET" && request.path == "/state") &&
            !(request.method == "POST" && request.path == "/cmd") {
            return .json(["error": "This action requires a trusted remote."], status: "403 Forbidden")
        }
        if request.path == "/devices" || request.path.hasPrefix("/devices/") {
            guard !device.isGuest else { return .json(["error": "Guests cannot manage devices"], status: "403 Forbidden") }
            switch (request.method, request.path) {
            case ("GET", "/devices"):
                return .json(pairing.activeDevices().map { d in
                    ["id": d.id, "name": d.name, "guest": d.isGuest, "current": d.id == device.id,
                     "expiresAt": d.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""] as [String: Any]
                })
            case ("POST", "/devices/revoke"):
                guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                      let id = object["id"] as? String else { return .json(["error": "Missing device"], status: "400 Bad Request") }
                do { try pairing.revoke(id: id); return .json(["ok": true]) }
                catch { return .json(["error": "Could not save changes"], status: "500 Internal Server Error") }
            case ("POST", "/devices/revoke-all"):
                do { try pairing.revokeAll(); legacyCode = nil; return .json(["ok": true]) }
                catch { return .json(["error": "Could not save changes"], status: "500 Internal Server Error") }
            default: return .json(["error": "Not found"], status: "404 Not Found")
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/state"):
            var snapshot = state()
            snapshot["guest"] = device.isGuest
            if device.isGuest {
                snapshot.removeValue(forKey: "currentLocalMovie")
                if let current = snapshot["current"] as? [String: Any], current["id"] as? String == "movies" {
                    snapshot["current"] = ["id": "movies", "name": "Movie"]
                }
            }
            return .json(snapshot)
        case ("POST", "/cmd"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let command = RemoteCommand(json: object)
            else { return .json(["error": "Unknown command"], status: "400 Bad Request") }
            if device.isGuest {
                guard Self.guestAllows(command) else {
                    return .json(["error": "This action requires a trusted remote."], status: "403 Forbidden")
                }
                if let onGuestCommand {
                    guard onGuestCommand(command) else {
                        return .json(["error": "This action requires a trusted remote here."], status: "403 Forbidden")
                    }
                } else {
                    guard Self.guestAllowsWithoutContext(command) else {
                        return .json(["error": "This action requires a trusted remote."], status: "403 Forbidden")
                    }
                    onCommand(command)
                }
            } else {
                onCommand(command)
            }
            return .json(["ok": true])
        default:
            return routes(request) ?? .json(["error": "Not found"], status: "404 Not Found")
        }
    }
    private static func guestAllowsWithoutContext(_ command: RemoteCommand) -> Bool {
        switch command {
        case .home, .playPause, .seek, .volume, .mute, .activateBrowser, .browserFullscreen:
            return true
        default: return false
        }
    }

    private static func guestAllows(_ command: RemoteCommand) -> Bool {
        switch command {
        case .move, .select, .back, .home, .playPause, .seek, .volume, .mute,
             .text, .deleteBackward, .pointer, .click, .scroll, .nextControl, .previousControl,
             .activateBrowser, .browserFullscreen, .retryBrowser:
            return true
        default: return false
        }
    }

}

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    var keepAlive: Bool { headers["connection"]?.lowercased() != "close" }

    enum ParseResult {
        case incomplete, invalid(String), complete(HTTPRequest, Int)
    }

    static func parse(_ data: Data) -> (HTTPRequest, Int)? {
        if case .complete(let request, let consumed) = parseResult(data) { return (request, consumed) }
        return nil
    }

    static func parseResult(_ data: Data) -> ParseResult {
        let headerLimit = 16 * 1024, bodyLimit = 1 << 20
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > headerLimit ? .invalid("431 Request Header Fields Too Large") : .incomplete
        }
        guard headerEnd.upperBound <= headerLimit,
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid("431 Request Header Fields Too Large")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, ["GET", "POST"].contains(String(requestLine[0])),
              ["HTTP/1.1", "HTTP/1.0"].contains(String(requestLine[2])),
              requestLine[1].hasPrefix("/") else { return .invalid("400 Bad Request") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .invalid("400 Bad Request") }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { return .invalid("400 Bad Request") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { return .invalid("400 Bad Request") }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { return .invalid("400 Bad Request") }
        guard length <= bodyLimit else { return .invalid("413 Payload Too Large") }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        guard let components = URLComponents(string: String(requestLine[1])), components.host == nil else { return .invalid("400 Bad Request") }
        var query: [String: String] = [:]
        components.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        let request = HTTPRequest(method: String(requestLine[0]), path: components.path, query: query, headers: headers,
                                  body: data.subdata(in: bodyStart..<bodyStart + length))
        return .complete(request, bodyStart + length)
    }

}

struct HTTPResponse {
    var status = "200 OK"
    var contentType = "application/json"
    var body = Data()

    static func json(_ object: Any, status: String = "200 OK") -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    func serialized(keepAlive: Bool) -> Data {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(head.utf8) + body
    }
}
