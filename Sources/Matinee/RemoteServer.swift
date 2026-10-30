import Foundation
import Network

/// A tiny HTTP server on the LAN: serves the phone remote page and accepts its commands.
/// Everything runs on the main queue.
final class RemoteServer {
    typealias CommandHandler = @MainActor (RemoteCommand) -> Void
    typealias StateProvider = @MainActor () -> [String: Any]
    typealias IconProvider = @MainActor (String) -> Data?
    typealias Routes = @MainActor (HTTPRequest) -> HTTPResponse?

    private let token: String
    private let onCommand: CommandHandler
    private let state: StateProvider
    private let icon: IconProvider
    private let routes: Routes
    private var listener: NWListener?
    private var failedAttempts: [Date] = []

    init(token: String, onCommand: @escaping CommandHandler, state: @escaping StateProvider,
         icon: @escaping IconProvider, routes: @escaping Routes) {
        self.token = token
        self.onCommand = onCommand
        self.state = state
        self.icon = icon
        self.routes = routes
    }

    /// The 6-digit code a phone needs, kept across launches so paired phones stay paired.
    static func pairingCode() -> String {
        let defaults = UserDefaults.standard
        if let code = defaults.string(forKey: "pairingCode") { return code }
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        defaults.set(code, forKey: "pairingCode")
        return code
    }

    /// Listens on the first free port in `ports`.
    func start(ports: [UInt16], onReady: @escaping @MainActor (UInt16) -> Void) {
        guard let port = ports.first, let nwPort = NWEndpoint.Port(rawValue: port) else {
            NSLog("Matinee: no free port for the phone remote")
            return
        }
        let tryNext = { [weak self] in self?.start(ports: Array(ports.dropFirst()), onReady: onReady) }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    MainActor.assumeIsolated { onReady(port) }
                case .failed:
                    listener.cancel()
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

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            // Browsers keep the connection open and send several requests on it.
            while let (request, consumed) = HTTPRequest.parse(buffer) {
                buffer = Data(buffer.dropFirst(consumed))
                let response = MainActor.assumeIsolated { self.respond(to: request) }
                let keepAlive = request.keepAlive
                connection.send(content: response.serialized(keepAlive: keepAlive),
                                completion: .contentProcessed { _ in if !keepAlive { connection.cancel() } })
                if !keepAlive { return }
            }

            if isComplete || error != nil || buffer.count > 1 << 20 {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    @MainActor
    private func respond(to request: HTTPRequest) -> HTTPResponse {
        if request.method == "GET", request.path == "/" {
            return HTTPResponse(contentType: "text/html; charset=utf-8", body: Data(RemotePage.html.utf8))
        }
        // App icons are public artwork; the phone shows them before pairing too.
        if request.method == "GET", request.path.hasPrefix("/icon/") {
            guard let png = icon(String(request.path.dropFirst("/icon/".count))) else {
                return .json(["error": "No icon"], status: "404 Not Found")
            }
            return HTTPResponse(contentType: "image/png", body: png)
        }

        // Slow down anyone guessing the pairing code.
        failedAttempts.removeAll { $0.timeIntervalSinceNow < -60 }
        guard failedAttempts.count < 20 else {
            return .json(["error": "Too many wrong codes. Try again in a minute."], status: "429 Too Many Requests")
        }
        guard request.headers["x-couch-key"] == token else {
            failedAttempts.append(Date())
            return .json(["error": "Wrong or missing pairing code"], status: "401 Unauthorized")
        }

        switch (request.method, request.path) {
        case ("GET", "/state"):
            return .json(state())
        case ("POST", "/cmd"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let command = RemoteCommand(json: object)
            else { return .json(["error": "Unknown command"], status: "400 Bad Request") }
            onCommand(command)
            return .json(["ok": true])
        default:
            return routes(request) ?? .json(["error": "Not found"], status: "404 Not Found")
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

    /// Parses one complete request from the front of `data`, returning it and the bytes it used.
    static func parse(_ data: Data) -> (HTTPRequest, Int)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
        else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }

        let components = URLComponents(string: String(requestLine[1]))
        var query: [String: String] = [:]
        components?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        let request = HTTPRequest(method: String(requestLine[0]), path: components?.path ?? "/", query: query, headers: headers,
                                  body: data.subdata(in: bodyStart..<bodyStart + length))
        return (request, bodyStart + length)
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
