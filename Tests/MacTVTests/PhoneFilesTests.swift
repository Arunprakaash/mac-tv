import Foundation
import Testing
@testable import MacTV

@Suite @MainActor
struct PhoneFilesTests {
    @Test func listsOnlyVisibleFoldersVideosAndSubtitles() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work/tests").appendingPathComponent("MacTV-PhoneFiles-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("Shows"), withIntermediateDirectories: true)
        for name in ["Film 2020.mkv", "Film.srt", "other.txt", ".hidden.mp4"] {
            try Data("test".utf8).write(to: root.appendingPathComponent(name))
        }
        let files = PhoneFiles(roots: [.init(name: "Fixtures", url: root)])
        let entries = try #require(try files.entries(in: PhoneFiles.id(for: root)))
        #expect(entries.map(\.name) == ["Shows", "Film 2020.mkv", "Film.srt"])
        #expect(entries.map(\.kind) == ["directory", "video", "subtitle"])
        #expect(entries[1].size == 4)
        let movie = try #require(files.movie(for: entries[1].id))
        #expect(movie.title == "Film")
        #expect(movie.year == 2020)
        #expect(files.movie(for: entries[2].id) == nil)
    }

    @Test func rejectsTraversalAndSymlinkEscapes() throws {
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work/tests").appendingPathComponent("MacTV-PhoneFiles-\(UUID().uuidString)", isDirectory: true)
        let root = fixture.appendingPathComponent("root", isDirectory: true)
        let outside = fixture.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let secret = outside.appendingPathComponent("secret.mp4")
        try Data().write(to: secret)
        let link = root.appendingPathComponent("escape.mp4")
        try fm.createSymbolicLink(at: link, withDestinationURL: secret)
        let files = PhoneFiles(roots: [.init(name: "Root", url: root)])
        #expect(files.resolve(PhoneFiles.id(for: secret)) == nil)
        #expect(files.resolve(PhoneFiles.id(for: link)) == nil)
        #expect(try files.entries(in: PhoneFiles.id(for: root))?.isEmpty == true)
        let traversal = Data((root.path + "/../outside/secret.mp4").utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        #expect(files.resolve(traversal) == nil)
        #expect(files.resolve("https://example.com") == nil)
        #expect(files.resolve("") == nil)
    }
}
