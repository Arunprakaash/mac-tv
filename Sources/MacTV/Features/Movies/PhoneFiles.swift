import Foundation

/// A bounded, read-only view of files beneath explicitly offered roots.
struct PhoneFiles {
    struct Root {
        let name: String
        let url: URL
    }
    struct Entry {
        let name: String
        let id: String
        let kind: String
        let size: Int64?
        var json: [String: Any] {
            var result: [String: Any] = ["name": name, "id": id, "kind": kind]
            if let size { result["size"] = size }
            return result
        }
    }
    private let roots: [Root]
    private let fileManager: FileManager
    private static let subtitles: Set<String> = ["srt", "ass", "vtt"]

    init(roots: [Root], fileManager: FileManager = .default) {
        self.roots = roots
        self.fileManager = fileManager
    }

    static func id(for url: URL) -> String {
        Data(url.standardizedFileURL.path.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// IDs are untrusted: decode only canonical absolute paths and check the resolved target.
    func resolve(_ id: String) -> URL? {
        guard !id.isEmpty, id.count <= 16384,
              id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        var encoded = id.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let path = String(data: data, encoding: .utf8),
              path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              path == URL(fileURLWithPath: path).standardizedFileURL.path else { return nil }
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard fileManager.fileExists(atPath: candidate.path), roots.contains(where: { root in
            let base = root.url.resolvingSymlinksInPath().standardizedFileURL.path
            return candidate.path == base || candidate.path.hasPrefix(base == "/" ? "/" : base + "/")
        }) else { return nil }
        return candidate
    }

    func rootEntries() -> [Entry] {
        roots.compactMap { root in
            let url = root.url.resolvingSymlinksInPath().standardizedFileURL
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else { return nil }
            return Entry(name: root.name, id: Self.id(for: url), kind: "directory", size: nil)
        }
    }

    func entries(in id: String) throws -> [Entry]? {
        guard let folder = resolve(id),
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        let urls = try fileManager.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isHiddenKey, .isPackageKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return urls.compactMap { url in
            guard !url.lastPathComponent.hasPrefix("."),
                  let resolved = resolve(Self.id(for: url)),
                  let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isHiddenKey, .isPackageKey, .fileSizeKey]),
                  values.isHidden != true, values.isPackage != true else { return nil }
            let kind: String
            if values.isDirectory == true { kind = "directory" }
            else if values.isRegularFile == true && MovieLibrary.extensions.contains(url.pathExtension.lowercased()) { kind = "video" }
            else if values.isRegularFile == true && Self.subtitles.contains(url.pathExtension.lowercased()) { kind = "subtitle" }
            else { return nil }
            return Entry(name: url.lastPathComponent, id: Self.id(for: resolved), kind: kind,
                         size: kind == "directory" ? nil : values.fileSize.map(Int64.init))
        }.sorted { a, b in
            if (a.kind == "directory") != (b.kind == "directory") { return a.kind == "directory" }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func movie(for id: String) -> Movie? {
        guard let url = resolve(id), MovieLibrary.extensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey]),
              values.isRegularFile == true else { return nil }
        let name = MovieName(url.deletingPathExtension().lastPathComponent)
        return Movie(path: url.path, title: name.title, year: name.year, episode: name.episode,
                     added: values.creationDate ?? Date(), size: Int64(values.fileSize ?? 0), poster: nil)
    }
}

@MainActor
extension TVController {
    func phoneFiles() -> PhoneFiles {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        // The whole home folder, with the usual video folders as shortcuts. Only the owner's paired phones
        // get here (RemoteServer turns guests away), and only folders, videos and subtitles are listed.
        var roots: [PhoneFiles.Root] = [
            .init(name: "Home", url: home),
            .init(name: "Movies", url: home.appendingPathComponent("Movies", isDirectory: true)),
            .init(name: "Downloads", url: home.appendingPathComponent("Downloads", isDirectory: true)),
            .init(name: "Desktop", url: home.appendingPathComponent("Desktop", isDirectory: true))
        ]
        let volumes = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: [.volumeIsInternalKey], options: .skipsHiddenFiles)) ?? []
        roots += volumes.filter { (try? $0.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) == false }
            .map { .init(name: $0.lastPathComponent, url: $0) }
        roots += MovieLibrary.shared.folders.map { .init(name: $0.lastPathComponent, url: $0) }
        var seen = Set<String>()
        return PhoneFiles(roots: roots.filter { seen.insert($0.url.resolvingSymlinksInPath().standardizedFileURL.path).inserted })
    }

    /// RemoteServer calls this only after pairing authentication.
    func handleFilesRequest(_ request: HTTPRequest) -> HTTPResponse? {
        guard request.path == "/files" || request.path.hasPrefix("/files/") else { return nil }
        let files = phoneFiles()
        switch (request.method, request.path) {
        case ("GET", "/files/roots"):
            return .json(["roots": files.rootEntries().map(\.json)])
        case ("GET", "/files"), ("GET", "/files/subtitles"):
            let isSubtitles = request.path == "/files/subtitles"
            let folder: String
            if isSubtitles {
                guard let id = request.query["movie"], let movie = files.movie(for: id) else {
                    return .json(["error": "Choose a valid movie."], status: "400 Bad Request")
                }
                folder = PhoneFiles.id(for: movie.url.deletingLastPathComponent())
            } else {
                guard let id = request.query["folder"] else { return .json(["error": "Choose a folder."], status: "400 Bad Request") }
                folder = id
            }
            do {
                guard var entries = try files.entries(in: folder) else { return .json(["error": "Folder unavailable."], status: "400 Bad Request") }
                if isSubtitles { entries = entries.filter { $0.kind == "subtitle" } }
                let offset = max(0, Int(request.query["offset"] ?? "0") ?? 0)
                let limit = min(200, max(1, Int(request.query["limit"] ?? "100") ?? 100))
                let start = min(offset, entries.count), end = min(start + limit, entries.count)
                var result: [String: Any] = ["entries": entries[start..<end].map(\.json), "offset": start]
                if end < entries.count { result["nextOffset"] = end }
                return .json(result)
            } catch { return .json(["error": "Could not read this folder."], status: "403 Forbidden") }
        case ("POST", "/files/play"):
            guard let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                  let id = body["id"] as? String, let player = body["player"] as? String,
                  let movie = files.movie(for: id), player == "native" || player == "iina" else {
                return .json(["error": "Choose a valid video and player."], status: "400 Bad Request")
            }
            if player == "iina" {
                guard playInIINA(movie, subtitle: nil) else { return .json(["error": "IINA is not available."], status: "409 Conflict") }
            } else { playMovie(movie, from: 0) }
            return .json(["ok": true])
        default:
            return .json(["error": "Not found"], status: "404 Not Found")
        }
    }
}
