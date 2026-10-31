import Foundation
import Testing
@testable import MacTV

struct SubtitleSupportTests {
    @Test func acceptsOnlySupportedSimpleNames() {
        #expect(SubtitleSupport.validExtension("episode.SRT") == "srt")
        #expect(SubtitleSupport.validExtension("episode.vtt") == "vtt")
        #expect(SubtitleSupport.validExtension("episode.ass") == "ass")
        #expect(SubtitleSupport.validExtension("../episode.srt") == nil)
        #expect(SubtitleSupport.validExtension("a\\b.srt") == nil)
        #expect(SubtitleSupport.validExtension("episode.srt.exe") == nil)
    }

    @Test func uploadStaysInAppFolderAndRejectsInvalidContent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work/tests").appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Subtitles", isDirectory: true)
        let support = SubtitleSupport(folder: folder)
        let file = try support.store(movieID: "/untrusted/path", name: "name.srt", content: "1\n00:00:01,000 --> 00:00:02,000\nHello")
        #expect(file.deletingLastPathComponent() == folder)
        #expect(!file.lastPathComponent.contains("name"))
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Hello"))
        #expect(throws: SubtitleError.self) { try support.store(movieID: "x", name: "../../x.srt", content: "text") }
        #expect(throws: SubtitleError.self) { try support.store(movieID: "x", name: "x.srt", content: "") }
        #expect(throws: SubtitleError.self) { try support.store(movieID: "x", name: "x.srt", content: "a\0b") }
        #expect(throws: SubtitleError.self) { try support.store(movieID: "x", name: "x.vtt", content: String(repeating: "a", count: SubtitleSupport.maxBytes + 1)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
    }

    @Test func refusesDocumentsDestination() {
        let documents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Subtitles", isDirectory: true)
        let support = SubtitleSupport(folder: documents)
        #expect(throws: SubtitleError.self) { try support.store(movieID: "x", name: "x.srt", content: "text") }
    }

    @Test func searchURLContainsEscapedTitleOnOfficialHost() throws {
        let url = try #require(SubtitleSupport.searchURL(title: "Film / & More"))
        #expect(url.host == "www.opensubtitles.org")
        #expect(url.absoluteString.contains("Film%20%2F%20%26%20More"))
        #expect(url.query == nil)
    }
}
