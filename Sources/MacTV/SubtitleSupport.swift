import Foundation
import CryptoKit

/// Validates uploaded text and writes only generated names in the app's own folder.
struct SubtitleSupport {
    static let maxBytes = 256 * 1024
    static let extensions: Set<String> = ["srt", "vtt", "ass"]
    let folder: URL

    init(folder: URL = AppFolder.url.appendingPathComponent("Subtitles", isDirectory: true)) {
        self.folder = folder
    }

    static func validExtension(_ name: String) -> String? {
        guard !name.isEmpty, name.utf8.count <= 255,
              name == (name as NSString).lastPathComponent,
              !name.contains("\\"), !name.contains("\0") else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        return extensions.contains(ext) ? ext : nil
    }

    func store(movieID: String, name: String, content: String) throws -> URL {
        guard let ext = Self.validExtension(name), !content.isEmpty,
              !content.contains("\0"), content.utf8.count <= Self.maxBytes else {
            throw SubtitleError.invalidUpload
        }
        let canonical = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
        let forbidden = [home.appendingPathComponent("Documents"), home.appendingPathComponent("Library/Mobile Documents"), home.appendingPathComponent("iCloud Drive (Archive)")]
        guard !forbidden.contains(where: { url in
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            return canonical == path || canonical.hasPrefix(path + "/")
        }) else { throw SubtitleError.invalidDestination }
        let digest = SHA256.hash(data: Data(movieID.utf8)).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("\(digest)-\(UUID().uuidString).\(ext)")
        try Data(content.utf8).write(to: target, options: .atomic)
        return target
    }

    static func searchURL(title: String) -> URL? {
        // The legacy OpenSubtitles search accepts a movie-name path component.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let escaped = title.addingPercentEncoding(withAllowedCharacters: allowed), !escaped.isEmpty else { return nil }
        return URL(string: "https://www.opensubtitles.org/en/search/sublanguageid-all/moviename-\(escaped)")
    }
}

enum SubtitleError: Error { case invalidUpload, invalidDestination }

@MainActor
extension TVController {
    /// Called after pairing authentication and before the generic file routes.
    func handleSubtitleRequest(_ request: HTTPRequest) -> HTTPResponse? {
        let paths: Set<String> = ["/files/subtitle", "/files/subtitle-upload", "/files/subtitle-search", "/files/subtitle-search-url"]
        guard paths.contains(request.path) else { return nil }
        let files = phoneFiles()
        if request.method == "GET", request.path == "/files/subtitle-search-url" {
            guard let id = request.query["movie"], let movie = files.movie(for: id),
                  let url = SubtitleSupport.searchURL(title: movie.title) else {
                return .json(["error": "Choose a valid movie."], status: "400 Bad Request")
            }
            return .json(["url": url.absoluteString])
        }
        guard request.method == "POST",
              let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let id = body["movie"] as? String, let movie = files.movie(for: id) else {
            return .json(["error": "Choose a valid movie."], status: "400 Bad Request")
        }
        switch request.path {
        case "/files/subtitle":
            guard let subtitleID = body["subtitle"] as? String, let subtitle = files.resolve(subtitleID),
                  SubtitleSupport.validExtension(subtitle.lastPathComponent) != nil,
                  (try? subtitle.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return .json(["error": "Choose a valid subtitle file."], status: "400 Bad Request")
            }
            guard playInIINA(movie, subtitle: subtitle) else {
                return .json(["error": "Could not open IINA with this subtitle."], status: "409 Conflict")
            }
        case "/files/subtitle-upload":
            guard let name = body["name"] as? String, let content = body["content"] as? String else {
                return .json(["error": "Choose a UTF-8 subtitle file."], status: "400 Bad Request")
            }
            do {
                let subtitle = try SubtitleSupport().store(movieID: id, name: name, content: content)
                guard playInIINA(movie, subtitle: subtitle) else {
                    return .json(["error": "Subtitle saved, but could not open IINA."], status: "409 Conflict")
                }
            } catch SubtitleError.invalidUpload {
                return .json(["error": "Use a non-empty .srt, .vtt or .ass file up to 256 KB."], status: "400 Bad Request")
            } catch {
                return .json(["error": "Could not save subtitle."], status: "500 Internal Server Error")
            }
        case "/files/subtitle-search":
            guard playInIINA(movie, subtitle: nil), searchIINASubtitles() else {
                return .json(["error": "Could not open IINA subtitle search."], status: "409 Conflict")
            }
        default:
            return .json(["error": "Not found"], status: "404 Not Found")
        }
        if request.path == "/files/subtitle-search" { return .json(["ok": true, "requested": true]) }
        return .json(["ok": true])
    }
}
