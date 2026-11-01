import AppKit
import AVFoundation

/// A video file on the Mac.
struct Movie: Codable, Identifiable, Hashable {
    let path: String
    var title: String
    var year: Int?
    /// "S1 E2", for files named like episodes.
    var episode: String?
    var added: Date
    var size: Int64
    /// The poster's file name in the Posters folder.
    var poster: String?
    /// True once a poster has been looked for, found or not.
    var posterChecked = false
    var duration: Double?
    /// Where playback stopped, in seconds; nil once finished.
    var position: Double?
    var lastWatched: Date?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var displayTitle: String { episode.map { "\(title) · \($0)" } ?? title }

    /// Partly watched: more than a minute in, and not at the end credits.
    var inProgress: Bool {
        guard let position, position > 60 else { return false }
        guard let duration, duration > 0 else { return true }
        return position < duration * 0.95
    }
}

/// Persists the watched folders and adds Downloads once for existing installations.
struct MovieFolderPreferences {
    private let defaults: UserDefaults
    private let movies: URL
    private let downloads: URL
    private let foldersKey = "movieFolders"
    private let migrationKey = "movieFoldersDownloadsAdded"

    init(defaults: UserDefaults = .standard, movies: URL, downloads: URL) {
        self.defaults = defaults
        self.movies = movies.standardizedFileURL
        self.downloads = downloads.standardizedFileURL
    }

    var folders: [URL] {
        get {
            var paths = defaults.stringArray(forKey: foldersKey)
                ?? [movies.path]
            if !defaults.bool(forKey: migrationKey) {
                if !paths.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path == downloads.path }) {
                    paths.append(downloads.path)
                }
                defaults.set(paths, forKey: foldersKey)
                defaults.set(true, forKey: migrationKey)
            }
            return paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        }
        nonmutating set {
            defaults.set(newValue.map { $0.standardizedFileURL.path }, forKey: foldersKey)
            defaults.set(true, forKey: migrationKey)
        }
    }
}

/// The movies in the folders you choose (Movies and Downloads to begin with), with posters and
/// where you stopped. Kept in ~/Library/Application Support/Mac TV/Movies. Posters come from
/// Apple's public movie search when the title matches exactly, otherwise from a frame of the film.
@MainActor
final class MovieLibrary: ObservableObject {
    static let shared = MovieLibrary()

    nonisolated static let extensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "ts", "m2ts", "mts", "mpg", "mpeg", "3gp"]

    @Published private(set) var movies: [Movie] = []
    @Published private(set) var scanning = false
    @Published private(set) var posters: [String: NSImage] = [:]

    private let folder = AppFolder.url.appendingPathComponent("Movies", isDirectory: true)
    private var postersFolder: URL { folder.appendingPathComponent("Posters", isDirectory: true) }
    private var listFile: URL { folder.appendingPathComponent("library.json") }
    private var offlineFile: URL { folder.appendingPathComponent("offline.json") }
    private var lookingUp = false
    /// Movies on a drive or network share that isn't connected right now, kept with where you stopped
    /// so they come back as they were.
    private var offline: [Movie] = []

    private init() {
        try? FileManager.default.createDirectory(at: postersFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: listFile), let saved = try? JSONDecoder().decode([Movie].self, from: data) {
            movies = saved
            saved.forEach(loadPoster)
        }
        if let data = try? Data(contentsOf: offlineFile), let saved = try? JSONDecoder().decode([Movie].self, from: data) {
            offline = saved
        }
    }

    // MARK: Folders

    private var folderPreferences: MovieFolderPreferences {
        MovieFolderPreferences(movies: Self.systemFolder(.moviesDirectory, fallback: "Movies"),
                               downloads: Self.systemFolder(.downloadsDirectory, fallback: "Downloads"))
    }

    /// The folders Mac TV looks in.
    var folders: [URL] {
        get { folderPreferences.folders }
        set {
            folderPreferences.folders = newValue
            objectWillChange.send()
        }
    }

    /// Folders worth offering: the usual places, drives, and any you chose yourself.
    var suggestedFolders: [URL] {
        var list = [Self.systemFolder(.moviesDirectory, fallback: "Movies"),
                    Self.systemFolder(.downloadsDirectory, fallback: "Downloads"),
                    Self.home("Desktop"), Self.home("Documents")].map(\.standardizedFileURL)
        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: [.volumeIsInternalKey],
            options: .skipsHiddenFiles)) ?? []
        list += volumes.filter { (try? $0.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) != true }
        // Network shares stay listed while they're offline, so they can be reconnected from here.
        for share in NetworkShares.shared.shares {
            if let folder = share.folder, !list.contains(folder) { list.append(folder) }
        }
        for chosen in folders where !list.contains(chosen) { list.append(chosen) }
        return list
    }

    func isWatched(_ folder: URL) -> Bool { folders.contains(folder.standardizedFileURL) }

    func toggle(_ folder: URL) {
        var list = folders
        let folder = folder.standardizedFileURL
        if let index = list.firstIndex(of: folder) { list.remove(at: index) } else { list.append(folder) }
        folders = list
        refresh()
    }

    func add(_ folder: URL) {
        let folder = folder.standardizedFileURL
        guard !folders.contains(folder) else { return }
        folders = folders + [folder]
        refresh()
    }

    private static func systemFolder(_ directory: FileManager.SearchPathDirectory, fallback: String) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask).first ?? home(fallback)
    }

    private static func home(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: Scanning

    /// Looks through the folders again, keeping what's known about files still there.
    func refresh() {
        guard !scanning else { return }
        scanning = true
        let roots = folders
        Task.detached(priority: .utility) {
            let found = Self.scan(roots)
            let missing = roots.filter { !FileManager.default.fileExists(atPath: $0.path) }
            await MainActor.run { self.merge(found, missing: missing) }
        }
    }

    private nonisolated static func scan(_ roots: [URL]) -> [(url: URL, added: Date, size: Int64)] {
        var found: [(URL, Date, Int64)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .addedToDirectoryDateKey, .creationDateKey]
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let file as URL in walker where extensions.contains(file.pathExtension.lowercased()) {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                // Skip clips and samples; a movie is bigger than this.
                let size = Int64(values.fileSize ?? 0)
                guard size > 20_000_000, !file.lastPathComponent.lowercased().contains("sample") else { continue }
                found.append((file, values.addedToDirectoryDate ?? values.creationDate ?? .distantPast, size))
            }
        }
        return found
    }

    private func merge(_ found: [(url: URL, added: Date, size: Int64)], missing: [URL]) {
        let known = Dictionary((movies + offline).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        // A folder that isn't there (a drive unplugged, a share offline): set its movies aside, don't forget them.
        let missingPrefixes = missing.map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
        let foundPaths = Set(found.map(\.url.path))
        offline = known.values.filter { movie in
            !foundPaths.contains(movie.path) && missingPrefixes.contains { movie.path.hasPrefix($0) }
        }
        movies = found.map { file in
            if var movie = known[file.url.path] {
                movie.size = file.size
                return movie
            }
            let name = MovieName(file.url.deletingPathExtension().lastPathComponent)
            return Movie(path: file.url.path, title: name.title, year: name.year, episode: name.episode,
                         added: file.added, size: file.size)
        }
        .sorted { $0.added != $1.added ? $0.added > $1.added : $0.title < $1.title }
        scanning = false
        save()
        lookUpPosters()
    }

    // MARK: Watching

    /// The Movies app's Top Shelf: what you're watching, then what's newest, that has a picture.
    var shelf: [(path: String, image: NSImage)] {
        var seen = Set<String>()
        return (continueWatching + movies).compactMap { movie in
            guard seen.insert(movie.path).inserted, let image = posters[movie.path] else { return nil }
            return (movie.path, image)
        }
        .prefix(8).map { $0 }
    }

    var continueWatching: [Movie] {
        movies.filter(\.inProgress).sorted { ($0.lastWatched ?? .distantPast) > ($1.lastWatched ?? .distantPast) }
    }

    func record(position: Double, duration: Double, for movie: Movie) {
        guard let index = movies.firstIndex(where: { $0.path == movie.path }) else { return }
        if duration > 0 { movies[index].duration = duration }
        let finished = duration > 0 && position >= duration * 0.95
        movies[index].position = finished ? nil : position
        movies[index].lastWatched = Date()
        save()
    }

    func movie(_ path: String) -> Movie? { movies.first { $0.path == path } }

    private func save() {
        if let data = try? JSONEncoder().encode(movies) { try? data.write(to: listFile, options: .atomic) }
        if let data = try? JSONEncoder().encode(offline) { try? data.write(to: offlineFile, options: .atomic) }
    }

    // MARK: Posters

    private func loadPoster(_ movie: Movie) {
        guard let name = movie.poster, posters[movie.path] == nil,
              let image = NSImage(contentsOf: postersFolder.appendingPathComponent(name)) else { return }
        posters[movie.path] = image
    }

    /// Finds posters for movies that don't have one yet, one at a time.
    private func lookUpPosters() {
        guard !lookingUp else { return }
        lookingUp = true
        Task {
            while let movie = movies.first(where: { !$0.posterChecked }) {
                let poster = await Self.findPoster(for: movie)
                var duration = movie.duration
                if duration == nil { duration = await Self.duration(of: movie.url) }
                guard let index = movies.firstIndex(where: { $0.path == movie.path }) else { continue }
                if let poster {
                    let name = "\(abs(movie.path.hashValue))-\(Int(Date().timeIntervalSince1970)).jpg"
                    try? poster.write(to: postersFolder.appendingPathComponent(name), options: .atomic)
                    movies[index].poster = name
                    loadPoster(movies[index])
                }
                movies[index].duration = duration
                movies[index].posterChecked = true
                save()
            }
            lookingUp = false
        }
    }

    private nonisolated static func findPoster(for movie: Movie) async -> Data? {
        if movie.episode == nil, let art = await appleArtwork(title: movie.title, year: movie.year),
           let (data, response) = try? await URLSession.shared.data(from: art),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            return data
        }
        let frame: CGImage?
        if ["mkv", "webm"].contains(movie.url.pathExtension.lowercased()) {
            frame = await Task.detached(priority: .utility) { MatroskaPlayback.frame(of: movie.url, at: 0.12) }.value
        } else {
            frame = await AVPlayback.frame(of: movie.url, at: 0.12)
        }
        guard let frame else { return nil }
        return NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// A poster from Apple's movie catalogue, when a film there has exactly this title (and year).
    private nonisolated static func appleArtwork(title: String, year: Int?) async -> URL? {
        guard let term = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        let wanted = simplified(title)
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        for country in Set([region, "us"]) {
            guard let url = URL(string: "https://itunes.apple.com/search?term=\(term)&country=\(country)&limit=25"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let results = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]]
            else { continue }
            let films = results.filter { $0["kind"] as? String == "feature-movie" && simplified($0["trackName"] as? String ?? "") == wanted }
            let match = films.first { film in
                guard let year, let released = (film["releaseDate"] as? String)?.prefix(4), let filmYear = Int(released) else { return true }
                return abs(filmYear - year) <= 1
            }
            if let art = match?["artworkUrl100"] as? String {
                return URL(string: art.replacingOccurrences(of: "100x100bb", with: "600x900bb"))
            }
        }
        return nil
    }

    private nonisolated static func simplified(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private nonisolated static func duration(of url: URL) async -> Double? {
        if ["mkv", "webm"].contains(url.pathExtension.lowercased()) {
            return await Task.detached(priority: .utility) {
                (try? MatroskaReader(url: url)).map { Double($0.duration) / 1e9 }
            }.value
        }
        let seconds = (try? await AVURLAsset(url: url).load(.duration))?.seconds ?? 0
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}

/// A file name tidied into a title: "www.site.com - Dorothy (2026) Tamil 1080p x264.mkv" → Dorothy, 2026;
/// "Show.Name.S01E02.720p.mkv" → Show Name, S1 E2.
struct MovieName {
    var title: String
    var year: Int?
    var episode: String?

    init(_ fileName: String) {
        var name = fileName
        // Leading release-site tags: "www.example.com - ", "[Group] ".
        name = name.replacingOccurrences(of: #"^\s*(www\.\S+|\[[^\]]*\])\s*[-–:]?\s*"#, with: "", options: .regularExpression)
        if !name.contains(" ") { name = name.replacingOccurrences(of: ".", with: " ") }
        name = name.replacingOccurrences(of: "_", with: " ")

        if let match = Self.match(#"^(.*?)[\s\-]*[Ss](\d{1,2})[\s\-]?[Ee](\d{1,3})"#, in: name), !match[1].isEmpty {
            title = Self.trim(match[1])
            episode = "S\(Int(match[2]) ?? 0) E\(Int(match[3]) ?? 0)"
            if title.isEmpty { title = name }
            return
        }
        if let match = Self.match(#"^(.+?)[\s(\[]+((?:19|20)\d{2})(?:[)\]\s]|$)"#, in: name), !Self.trim(match[1]).isEmpty {
            title = Self.trim(match[1])
            year = Int(match[2])
            return
        }
        let quality = #"(?i)\b(2160p|1080p|720p|576p|480p|4k|uhd|x264|x265|h\.?264|h\.?265|hevc|web[- ]?dl|webrip|bluray|brrip|bdrip|hdrip|dvdrip|predvd|hdtv|hdcam|aac|ac3|ddp?5|10bit)\b"#
        if let range = name.range(of: quality, options: .regularExpression), !Self.trim(String(name[..<range.lowerBound])).isEmpty {
            name = String(name[..<range.lowerBound])
        }
        title = Self.trim(name)
        if title.isEmpty { title = fileName }
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " -–([{.,:"))
    }

    private static func match(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
