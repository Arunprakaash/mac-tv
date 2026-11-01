import AppKit
import Security

/// Jellyfin servers: someone runs Jellyfin with their movies, makes you a user, and you sign in
/// here once. Its movies and episodes join Movies and play in Mac TV's own player; Jellyfin
/// converts what the player can't open, and hears where you stopped so its other apps resume
/// there too. Only the sign-in token is kept, in the Keychain; never the password.
@MainActor
final class JellyfinServers: ObservableObject {
    static let shared = JellyfinServers()

    struct Server: Codable, Identifiable, Equatable {
        /// The server's own ID.
        let id: String
        var name: String
        /// "http://192.168.1.5:8096", without a trailing slash.
        var address: String
        var userID: String
        var user: String
        /// Off hides its movies without signing out.
        var on: Bool
    }

    /// A movie ready to play: where to stream it from, and what to tell the server about it.
    struct Stream {
        let url: URL
        let item: String
        let source: String
        let session: String
        let direct: Bool
    }

    enum Failure: Error {
        case http(Int)
        case notJellyfin
    }

    /// Why a movie can't play, for the toast.
    struct Problem: Error {
        let message: String
    }

    /// Movies from a server have paths like jellyfin://<server>/<item>.
    nonisolated static let scheme = "jellyfin://"

    @Published private(set) var servers: [Server] = []
    @Published private(set) var status: [String: NetworkShares.Status] = [:]
    /// A sign-in in progress, or why the last one failed, for the phone.
    @Published private(set) var signingIn = false
    @Published private(set) var signInError: String?

    private let file = AppFolder.url.appendingPathComponent("jellyfin-servers.json")
    /// What's playing, so the server can resume it elsewhere and stop converting when it ends.
    private var playing: (stream: Stream, server: Server)?

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Server].self, from: data) {
            servers = saved
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) { try? data.write(to: file, options: .atomic) }
    }

    func server(for path: String) -> Server? {
        guard let ids = Self.ids(in: path) else { return nil }
        return servers.first { $0.id == ids.server }
    }

    // MARK: Signing in

    /// Signs in and adds the server, or says why it couldn't.
    @discardableResult
    func signIn(address typed: String, user: String, password: String) async -> String? {
        signingIn = true
        signInError = nil
        let error = await attempt(address: typed, user: user, password: password)
        signInError = error
        signingIn = false
        return error
    }

    /// The phone's sign-in: it's under way as soon as this returns, so the phone's first look sees it.
    func startSignIn(address: String, user: String, password: String) {
        signingIn = true
        signInError = nil
        Task { await signIn(address: address, user: user, password: password) }
    }

    private func attempt(address typed: String, user: String, password: String) async -> String? {
        guard let base = Self.address(typed) else {
            return typed.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Type the server's address first." : "Use an address like 192.168.1.5:8096."
        }
        let user = user.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { return "Type your Jellyfin user name." }
        let address = await Self.tailscaleName(for: base).absoluteString
        do {
            guard let info = try await Self.call(Self.request(address, "/System/Info/Public")) as? [String: Any],
                  let id = info["Id"] as? String else { throw Failure.notJellyfin }
            let reply = try await Self.call(Self.request(address, "/Users/AuthenticateByName",
                                                         body: ["Username": user, "Pw": password])) as? [String: Any]
            guard let token = reply?["AccessToken"] as? String,
                  let userID = (reply?["User"] as? [String: Any])?["Id"] as? String else { throw Failure.http(401) }
            let server = Server(id: id, name: info["ServerName"] as? String ?? base.host ?? "Jellyfin",
                                address: address, userID: userID, user: user, on: true)
            servers.removeAll { $0.id == id }
            servers.append(server)
            JellyfinKeychain.save(token, server: id)
            status[id] = .connected
            save()
            MovieLibrary.shared.refresh()
            return nil
        } catch {
            return Self.message(for: error, signingIn: true)
        }
    }

    /// Signs out and forgets the server; its movies leave Movies.
    func remove(_ id: String) {
        guard let server = servers.first(where: { $0.id == id }) else { return }
        if let token = JellyfinKeychain.token(server: id) {
            let request = Self.request(server.address, "/Sessions/Logout", token: token, body: [String: Any]())
            Task.detached { _ = try? await Self.call(request) }
        }
        JellyfinKeychain.delete(server: id)
        servers.removeAll { $0.id == id }
        status[id] = nil
        save()
        MovieLibrary.shared.refresh()
    }

    /// The Folders sheet's row: switches a reachable server's movies on or off, or tries again.
    func activate(_ server: Server) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        if !server.on || status[server.id] == .connected {
            servers[index].on.toggle()
            save()
        } else {
            status[server.id] = .connecting
        }
        MovieLibrary.shared.refresh()
    }

    fileprivate func update(_ id: String, _ value: NetworkShares.Status) { status[id] = value }

    // MARK: Library

    /// Every movie and episode on the servers, and the servers that couldn't be reached (as path
    /// prefixes, so their movies are set aside rather than forgotten).
    nonisolated static func movies(on servers: [Server]) async -> (movies: [Movie], unreachable: [String]) {
        var movies: [Movie] = []
        var unreachable: [String] = []
        for server in servers {
            do {
                guard let token = JellyfinKeychain.token(server: server.id) else { throw Failure.http(401) }
                let query = ["userId": server.userID, "includeItemTypes": "Movie,Episode", "recursive": "true",
                             "fields": "DateCreated", "enableUserData": "true", "enableImageTypes": "Primary",
                             "imageTypeLimit": "1"]
                let reply = try await call(request(server.address, "/Items", query: query, token: token)) as? [String: Any]
                let items = reply?["Items"] as? [[String: Any]] ?? []
                movies += items.compactMap { movie(from: $0, server: server) }
                await shared.update(server.id, .connected)
            } catch {
                unreachable.append(scheme + server.id)
                await shared.update(server.id, .offline(message(for: error, signingIn: false)))
            }
        }
        return (movies, unreachable)
    }

    /// A Movie from one of the server's items.
    nonisolated static func movie(from item: [String: Any], server: Server) -> Movie? {
        guard let id = item["Id"] as? String, let name = item["Name"] as? String else { return nil }
        let isEpisode = item["Type"] as? String == "Episode"
        var episode: String?
        if isEpisode, let number = item["IndexNumber"] as? Int {
            episode = "S\(item["ParentIndexNumber"] as? Int ?? 1) E\(number)"
        }
        let year = item["ProductionYear"] as? Int
        var title = isEpisode ? item["SeriesName"] as? String ?? name : name
        // Films Jellyfin couldn't look up keep their folder's name: "Title (2026)".
        if let year, title.hasSuffix(" (\(year))") { title = String(title.dropLast(" (\(year))".count)) }
        var movie = Movie(path: scheme + server.id + "/" + id, title: title, year: year, episode: episode,
                          added: date(item["DateCreated"]) ?? .distantPast, size: 0)
        movie.server = server.name
        if let ticks = (item["RunTimeTicks"] as? NSNumber)?.doubleValue, ticks > 0 { movie.duration = ticks / 10_000_000 }
        let user = item["UserData"] as? [String: Any]
        if let ticks = (user?["PlaybackPositionTicks"] as? NSNumber)?.doubleValue, ticks > 0 { movie.position = ticks / 10_000_000 }
        movie.lastWatched = date(user?["LastPlayedDate"])
        // Episodes use their show's poster; their own pictures are wide frames.
        if isEpisode, let series = item["SeriesId"] as? String, item["SeriesPrimaryImageTag"] != nil {
            movie.artwork = series
        } else if (item["ImageTags"] as? [String: Any])?["Primary"] != nil {
            movie.artwork = id
        } else {
            movie.posterChecked = true
        }
        return movie
    }

    nonisolated static func poster(for movie: Movie, on server: Server) async -> Data? {
        guard let artwork = movie.artwork else { return nil }
        let request = request(server.address, "/Items/\(artwork)/Images/Primary", query: ["maxHeight": "900", "quality": "90"],
                              token: JellyfinKeychain.token(server: server.id))
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: Playing

    /// Asks the server how to play the movie: the file itself when the player can open it,
    /// otherwise Jellyfin repackages or converts it as it streams.
    func stream(for movie: Movie) async -> Result<Stream, Problem> {
        guard let ids = Self.ids(in: movie.path), let server = server(for: movie.path),
              let token = JellyfinKeychain.token(server: server.id) else {
            return .failure(Problem(message: "Sign in to \(movie.server ?? "the server") again in Movies › Folders."))
        }
        let body: [String: Any] = ["UserId": server.userID, "DeviceProfile": Self.profile, "AutoOpenLiveStream": true,
                                   "EnableDirectPlay": true, "EnableDirectStream": true, "EnableTranscoding": true,
                                   "AllowVideoStreamCopy": true, "AllowAudioStreamCopy": true]
        do {
            let reply = try await Self.call(Self.request(server.address, "/Items/\(ids.item)/PlaybackInfo",
                                                         query: ["userId": server.userID], token: token, body: body)) as? [String: Any]
            guard let source = (reply?["MediaSources"] as? [[String: Any]])?.first, let sourceID = source["Id"] as? String else {
                return .failure(Problem(message: "\(server.name) has no video for \(movie.title)."))
            }
            let session = reply?["PlaySessionId"] as? String ?? UUID().uuidString
            var url: URL?
            let direct = source["SupportsDirectPlay"] as? Bool == true
            if direct {
                url = Self.url(server.address, "/Videos/\(ids.item)/stream",
                               query: ["static": "true", "mediaSourceId": sourceID, "playSessionId": session, "ApiKey": token])
            } else if let path = source["TranscodingUrl"] as? String {
                let separator = path.contains("?") ? "&" : "?"
                url = URL(string: server.address + path + (path.contains("ApiKey=") ? "" : "\(separator)ApiKey=\(token)"))
            }
            guard let url else { return .failure(Problem(message: "\(server.name) can't stream \(movie.title).")) }
            return .success(Stream(url: url, item: ids.item, source: sourceID, session: session, direct: direct))
        } catch {
            return .failure(Problem(message: Self.message(for: error, signingIn: false) + ": \(server.name)"))
        }
    }

    func started(_ stream: Stream, movie: Movie, at seconds: Double) {
        guard let server = server(for: movie.path) else { return }
        playing = (stream, server)
        report("/Sessions/Playing", position: seconds, extra: ["CanSeek": true, "PlayMethod": stream.direct ? "DirectPlay" : "Transcode"])
    }

    func progress(_ movie: Movie, at seconds: Double, paused: Bool) {
        guard playing?.stream.item == Self.ids(in: movie.path)?.item else { return }
        report("/Sessions/Playing/Progress", position: seconds, extra: ["IsPaused": paused, "CanSeek": true])
    }

    /// Playback ended: the server keeps the place (or marks it watched) and stops converting.
    func stopped(_ movie: Movie, at seconds: Double) {
        guard playing?.stream.item == Self.ids(in: movie.path)?.item else { return }
        report("/Sessions/Playing/Stopped", position: seconds, extra: [:])
        playing = nil
    }

    private func report(_ path: String, position: Double, extra: [String: Any]) {
        guard let (stream, server) = playing, let token = JellyfinKeychain.token(server: server.id) else { return }
        var body = extra
        body["ItemId"] = stream.item
        body["MediaSourceId"] = stream.source
        body["PlaySessionId"] = stream.session
        body["PositionTicks"] = Int64(max(0, position) * 10_000_000)
        let request = Self.request(server.address, path, token: token, body: body)
        Task.detached { _ = try? await Self.call(request) }
    }

    /// What Mac TV's player opens itself; Jellyfin converts the rest to HLS in fragmented MP4,
    /// copying the picture and sound when it can.
    nonisolated static let profile: [String: Any] = [
        "Name": "Mac TV",
        "MaxStreamingBitrate": 120_000_000,
        "MaxStaticBitrate": 120_000_000,
        "DirectPlayProfiles": [["Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": "h264,hevc",
                                "AudioCodec": "aac,ac3,eac3,mp3,alac,flac"]],
        "TranscodingProfiles": [["Container": "mp4", "Type": "Video", "Protocol": "hls", "Context": "Streaming",
                                 "VideoCodec": "hevc,h264", "AudioCodec": "aac,ac3,eac3", "MaxAudioChannels": "6",
                                 "MinSegments": 1, "BreakOnNonKeyFrames": true]],
        "SubtitleProfiles": [["Format": "vtt", "Method": "Hls"]],
    ]

    // MARK: Requests

    /// "192.168.1.5", "nas.local:8096", "https://tv.example.com/jellyfin" or a pasted
    /// "http://host:8096/web/#/home": the server's base address. Plain HTTP without a port means 8096.
    nonisolated static func address(_ typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host, !host.isEmpty else { return nil }
        parts.scheme = scheme
        if parts.port == nil, scheme == "http" { parts.port = 8096 }
        if let web = parts.path.range(of: "/web") { parts.path = String(parts.path[..<web.lowerBound]) }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.url
    }

    /// Tailscale's 100.x addresses are in the shared 100.64.0.0/10 range.
    nonisolated static func isTailscaleAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// macOS refuses plain HTTP to another machine's Tailscale number but allows its Tailscale
    /// name (Info.plist allows ts.net), so a typed 100.x address becomes the name Tailscale gives it.
    nonisolated static func tailscaleName(for url: URL) async -> URL {
        guard let host = url.host, isTailscaleAddress(host) else { return url }
        let name = await Task.detached(priority: .userInitiated) { () -> String? in
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let found = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &name, socklen_t(name.count), nil, 0, NI_NAMEREQD)
                }
            }
            return found == 0 ? String(cString: name) : nil
        }.value
        guard let name = name?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), name.hasSuffix(".ts.net"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.host = name
        return parts.url ?? url
    }

    nonisolated static func ids(in path: String) -> (server: String, item: String)? {
        guard path.hasPrefix(scheme) else { return nil }
        let parts = path.dropFirst(scheme.count).split(separator: "/")
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private nonisolated static func url(_ address: String, _ path: String, query: [String: String] = [:]) -> URL? {
        guard var parts = URLComponents(string: address + path) else { return nil }
        if !query.isEmpty { parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return parts.url
    }

    private nonisolated static func request(_ address: String, _ path: String, query: [String: String] = [:],
                                            token: String? = nil, body: Any? = nil) -> URLRequest {
        var request = URLRequest(url: url(address, path, query: query) ?? URL(string: "http://invalid")!, timeoutInterval: 20)
        request.setValue(authorization(token: token), forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private nonisolated static func authorization(token: String?) -> String {
        let device = (Host.current().localizedName ?? "Mac").replacingOccurrences(of: "\"", with: "")
        var fields = ["Client=\"Mac TV\"", "Device=\"\(device)\"", "DeviceId=\"\(deviceID)\"",
                      "Version=\"\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")\""]
        if let token { fields.append("Token=\"\(token)\"") }
        return "MediaBrowser " + fields.joined(separator: ", ")
    }

    /// One ID for this Mac, so the server lists it as a single device.
    private nonisolated static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "jellyfinDeviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "jellyfinDeviceID")
        return id
    }

    private nonisolated static func call(_ request: URLRequest) async throws -> Any {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure.http(code) }
        return data.isEmpty ? [String: Any]() : try JSONSerialization.jsonObject(with: data)
    }

    nonisolated static func message(for error: Error, signingIn: Bool) -> String {
        switch error {
        case Failure.http(401), Failure.http(403):
            return signingIn ? "Wrong user name or password" : "Sign in again"
        case Failure.notJellyfin, is DecodingError, is CocoaError:
            return "Not a Jellyfin server"
        case let error as URLError:
            return message(for: error)
        case Failure.http(let code):
            return "The server answered \(code)"
        default:
            return "Couldn't connect"
        }
    }

    /// What went wrong on the way to the server, as exactly as the error says.
    nonisolated static func message(for error: URLError) -> String {
        let place = error.failingURL.flatMap { url in url.host.map { host in url.port.map { "\(host):\($0)" } ?? host } } ?? "the server"
        // macOS reports a refused Local Network permission only in the error's network path.
        if String(describing: error.userInfo).localizedCaseInsensitiveContains("local network prohibited") {
            return "Allow Mac TV in System Settings › Privacy & Security › Local Network"
        }
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed: return "Can't find \(place)"
        case .cannotConnectToHost: return "Nothing is answering at \(place)"
        case .timedOut: return "No answer from \(place)"
        case .notConnectedToInternet, .networkConnectionLost: return "This Mac isn't connected"
        case .appTransportSecurityRequiresSecureConnection:
            return error.failingURL?.host.map(isTailscaleAddress) == true
                ? "Use the server's Tailscale name, like mac.tailnet.ts.net:8096" : "Use the server's IP address, or https://"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: return "The server's certificate isn't trusted"
        default: return "Can't reach \(place) (\(error.code.rawValue))"
        }
    }

    /// Jellyfin's dates have seven decimal places, more than ISO8601DateFormatter reads.
    nonisolated static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

/// Jellyfin sign-in tokens in the login Keychain, one per server, labelled as Mac TV's.
enum JellyfinKeychain {
    private static func query(server: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Mac TV Jellyfin",
         kSecAttrAccount as String: server]
    }

    static func save(_ token: String, server: String) {
        SecItemDelete(query(server: server) as CFDictionary)
        var item = query(server: server)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrLabel as String] = "Mac TV Jellyfin sign-in"
        SecItemAdd(item as CFDictionary, nil)
    }

    static func token(server: String) -> String? {
        var item = query(server: server)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(server: String) {
        SecItemDelete(query(server: server) as CFDictionary)
    }
}

extension TVController {
    /// The phone's Jellyfin section. Trusted remotes only: the server turns guests away.
    func handleJellyfinRequest(_ request: HTTPRequest) -> HTTPResponse? {
        guard request.path == "/jellyfin" || request.path.hasPrefix("/jellyfin/") else { return nil }
        let jellyfin = JellyfinServers.shared
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        switch (request.method, request.path) {
        case ("GET", "/jellyfin"):
            var reply: [String: Any] = [
                "servers": jellyfin.servers.map { server in
                    let status = jellyfin.status[server.id] ?? .connecting
                    return ["id": server.id, "name": server.name, "address": server.address, "user": server.user,
                            "connected": status == .connected, "status": server.on ? status.text : "Off"] as [String: Any]
                },
                "signingIn": jellyfin.signingIn,
            ]
            if let error = jellyfin.signInError { reply["error"] = error }
            return .json(reply)
        case ("POST", "/jellyfin/add"):
            let address = body["address"] as? String ?? ""
            guard JellyfinServers.address(address) != nil else {
                return .json(["error": "Enter the server's address, e.g. 192.168.1.5:8096."], status: "400 Bad Request")
            }
            let user = body["user"] as? String ?? "", password = body["password"] as? String ?? ""
            jellyfin.startSignIn(address: address, user: user, password: password)
            return .json(["ok": true])
        case ("POST", "/jellyfin/remove"):
            guard let id = body["id"] as? String else { return .json(["error": "Choose a server."], status: "400 Bad Request") }
            jellyfin.remove(id)
            return .json(["ok": true])
        default:
            return .json(["error": "Not found"], status: "404 Not Found")
        }
    }
}
