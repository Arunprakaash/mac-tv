import AppKit
import NetFS
import Network
import Security

/// Shared folders on a NAS or another computer (SMB), added once and kept connected: at launch,
/// after waking, when the network comes back, and every couple of minutes while one is offline.
/// Passwords live in the Mac's Keychain. A connected share is an ordinary drive under /Volumes, so
/// Movies, the player, IINA and Files on Mac all use it as they would any folder.
@MainActor
final class NetworkShares: ObservableObject {
    static let shared = NetworkShares()

    struct Share: Codable, Identifiable, Equatable {
        let id: String
        var host: String
        var share: String
        /// A folder inside the share, or "" for all of it.
        var subpath: String
        /// "" connects as a guest.
        var user: String
        /// Where macOS put it the last time it connected, so its movies keep their place while it's offline.
        var mountPath: String?

        var name: String { subpath.isEmpty ? share : (subpath as NSString).lastPathComponent }
        var address: String { "smb://\(host)/\(share)" + (subpath.isEmpty ? "" : "/\(subpath)") }
        var mountURL: URL? {
            guard let encoded = share.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
            return URL(string: "smb://\(host)/\(encoded)")
        }
        /// The folder Movies looks in.
        var folder: URL? {
            mountPath.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(subpath, isDirectory: true).standardizedFileURL }
        }
    }

    enum Status: Equatable {
        case connecting, connected
        case offline(String)

        var text: String {
            switch self {
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case .offline(let reason): reason
            }
        }
    }

    @Published private(set) var shares: [Share] = []
    @Published private(set) var status: [String: Status] = [:]

    private let file = AppFolder.url.appendingPathComponent("network-shares.json")
    private var monitor: NWPathMonitor?
    private var timer: Timer?
    private var lastPathSatisfied = false

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Share].self, from: data) {
            shares = saved
        }
    }

    func start() {
        connectAll()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            MainActor.assumeIsolated { NetworkShares.shared.connectAll() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                let shares = NetworkShares.shared
                // The network just came back: give it a moment, then reconnect.
                if satisfied && !shares.lastPathSatisfied {
                    try? await Task.sleep(for: .seconds(3))
                    shares.connectAll()
                }
                shares.lastPathSatisfied = satisfied
            }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                NetworkShares.shared.connectAll()
            }
        }
    }

    func share(for folder: URL) -> Share? {
        let folder = folder.standardizedFileURL
        return shares.first { $0.folder == folder }
    }

    // MARK: Adding and removing

    /// "nas.local/Movies", "smb://nas.local/Movies/Films" or "\\nas\Movies": host, share, and a folder inside it.
    nonisolated static func parse(_ address: String) -> (host: String, share: String, subpath: String, user: String)? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 1024, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        if text.hasPrefix("\\\\") { text = String(text.dropFirst(2)).replacingOccurrences(of: "\\", with: "/") }
        if let scheme = text.range(of: "://") {
            guard text[..<scheme.lowerBound].lowercased() == "smb" else { return nil }
            text = String(text[scheme.upperBound...])
        }
        let parts = text.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        var host = parts[0], user = ""
        if let at = host.lastIndex(of: "@") {
            user = String(host[..<at]).removingPercentEncoding ?? String(host[..<at])
            host = String(host[host.index(after: at)...])
        }
        guard !host.isEmpty, !host.contains(where: \.isWhitespace) else { return nil }
        let decode = { (part: String) in part.removingPercentEncoding ?? part }
        return (host, decode(parts[1]), parts.dropFirst(2).map(decode).joined(separator: "/"), user)
    }

    /// Adds a share (or updates one with the same address) and connects it; its folder joins Movies once connected.
    @discardableResult
    func add(address: String, user: String, password: String) -> Share? {
        guard let parsed = Self.parse(address) else { return nil }
        let account = user.isEmpty ? parsed.user : user
        var share = Share(id: String(UUID().uuidString.prefix(8)).lowercased(), host: parsed.host, share: parsed.share,
                          subpath: parsed.subpath, user: account, mountPath: nil)
        if let index = shares.firstIndex(where: { $0.host.lowercased() == share.host.lowercased() && $0.share == share.share && $0.subpath == share.subpath }) {
            share = Share(id: shares[index].id, host: share.host, share: share.share, subpath: share.subpath,
                          user: account, mountPath: shares[index].mountPath)
            shares[index] = share
        } else {
            shares.append(share)
        }
        if !account.isEmpty {
            ShareKeychain.save(password, host: share.host, user: account)
        }
        save()
        connect(share, addToMovies: true)
        return share
    }

    /// Forgets a share and its password. It stays connected in Finder if it was; Movies stops looking in it.
    func remove(_ id: String) {
        guard let index = shares.firstIndex(where: { $0.id == id }) else { return }
        let share = shares.remove(at: index)
        status[id] = nil
        if !share.user.isEmpty, !shares.contains(where: { $0.host == share.host && $0.user == share.user }) {
            ShareKeychain.delete(host: share.host, user: share.user)
        }
        if let folder = share.folder, MovieLibrary.shared.isWatched(folder) { MovieLibrary.shared.toggle(folder) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shares) { try? data.write(to: file, options: .atomic) }
    }

    // MARK: Connecting

    func connectAll() {
        for share in shares where status[share.id] != .connecting { connect(share, addToMovies: false) }
    }

    func connect(_ share: Share, addToMovies: Bool) {
        guard let url = share.mountURL else { status[share.id] = .offline("Check the address"); return }
        // Already connected, by Mac TV earlier or in Finder: nothing to do but note where.
        if let mounted = Self.mountedPath(host: share.host, share: share.share) {
            connected(share.id, at: mounted, addToMovies: addToMovies)
            return
        }
        status[share.id] = .connecting
        let password = share.user.isEmpty ? nil : ShareKeychain.read(host: share.host, user: share.user)
        let user = share.user
        DispatchQueue.global(qos: .utility).async {
            let result = Self.mount(url, user: user, password: password)
            Task { @MainActor in
                let shares = NetworkShares.shared
                guard shares.shares.contains(where: { $0.id == share.id }) else { return }
                if let path = result.path ?? Self.mountedPath(host: share.host, share: share.share) {
                    shares.connected(share.id, at: path, addToMovies: addToMovies)
                } else {
                    shares.status[share.id] = .offline(Self.message(for: result.error))
                }
            }
        }
    }

    private func connected(_ id: String, at path: String, addToMovies: Bool) {
        guard let index = shares.firstIndex(where: { $0.id == id }) else { return }
        let wasOffline = status[id] != .connected
        status[id] = .connected
        if shares[index].mountPath != path {
            shares[index].mountPath = path
            save()
        }
        guard let folder = shares[index].folder else { return }
        if addToMovies {
            MovieLibrary.shared.add(folder)
        } else if wasOffline, MovieLibrary.shared.isWatched(folder) {
            MovieLibrary.shared.refresh()
        }
    }

    /// Where a share is mounted right now, if it is.
    nonisolated static func mountedPath(host: String, share: String) -> String? {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey],
                                                            options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            guard let remote = try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting,
                  remote.scheme?.lowercased() == "smb",
                  remote.host?.lowercased() == host.split(separator: ":").first.map({ $0.lowercased() }) else { continue }
            let remoteShare = remote.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if remoteShare.caseInsensitiveCompare(share) == .orderedSame { return volume.path }
        }
        return nil
    }

    /// Mounts without showing any macOS dialog, so nothing appears over the TV.
    nonisolated static func mount(_ url: URL, user: String, password: String?) -> (path: String?, error: Int32) {
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey as String] = kNAUIOptionNoUI as String
        if user.isEmpty { openOptions[kNetFSUseGuestKey as String] = true }
        var mountpoints: Unmanaged<CFArray>?
        let error = NetFSMountURLSync(url as CFURL, nil, user.isEmpty ? nil : user as CFString, password as CFString?,
                                      openOptions, NSMutableDictionary(), &mountpoints)
        let paths = mountpoints?.takeRetainedValue() as? [String]
        return (paths?.first, error)
    }

    nonisolated static func message(for error: Int32) -> String {
        switch error {
        case 80, -6003, -5045, 13, 1: "Wrong user name or password"
        case 2: "Shared folder not found"
        case 60, 64, 65, 51, -6600, -5998: "Server not reachable"
        default: "Couldn't connect (\(error))"
        }
    }
}

/// Network share passwords in the login Keychain, labelled so Mac TV only ever reads its own.
enum ShareKeychain {
    private static let label = "Mac TV network share"

    private static func query(host: String, user: String) -> [String: Any] {
        [kSecClass as String: kSecClassInternetPassword,
         kSecAttrServer as String: host,
         kSecAttrAccount as String: user,
         kSecAttrProtocol as String: kSecAttrProtocolSMB,
         kSecAttrLabel as String: label]
    }

    static func save(_ password: String, host: String, user: String) {
        SecItemDelete(query(host: host, user: user) as CFDictionary)
        var item = query(host: host, user: user)
        item[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read(host: String, user: String) -> String? {
        var item = query(host: host, user: user)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(host: String, user: String) {
        SecItemDelete(query(host: host, user: user) as CFDictionary)
    }
}

extension TVController {
    /// The phone's Network Shares section. Trusted remotes only: the server turns guests away.
    func handleSharesRequest(_ request: HTTPRequest) -> HTTPResponse? {
        guard request.path == "/shares" || request.path.hasPrefix("/shares/") else { return nil }
        let shares = NetworkShares.shared
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        switch (request.method, request.path) {
        case ("GET", "/shares"):
            return .json(shares.shares.map { share in
                let status = shares.status[share.id] ?? .connecting
                return ["id": share.id, "name": share.name, "address": share.address, "user": share.user,
                        "connected": status == .connected, "connecting": status == .connecting, "status": status.text]
            })
        case ("POST", "/shares/add"):
            guard let address = body["address"] as? String,
                  shares.add(address: address, user: body["user"] as? String ?? "", password: body["password"] as? String ?? "") != nil else {
                return .json(["error": "Enter a shared folder like nas.local/Movies."], status: "400 Bad Request")
            }
            return .json(["ok": true])
        case ("POST", "/shares/remove"):
            guard let id = body["id"] as? String else { return .json(["error": "Choose a share."], status: "400 Bad Request") }
            shares.remove(id)
            return .json(["ok": true])
        case ("POST", "/shares/connect"):
            guard let id = body["id"] as? String, let share = shares.shares.first(where: { $0.id == id }) else {
                return .json(["error": "Choose a share."], status: "400 Bad Request")
            }
            shares.connect(share, addToMovies: false)
            return .json(["ok": true])
        default:
            return .json(["error": "Not found"], status: "404 Not Found")
        }
    }
}
