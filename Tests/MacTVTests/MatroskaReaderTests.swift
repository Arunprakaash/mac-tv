import Foundation
import Testing
@testable import MacTV

/// Small Matroska files built byte by byte, so the reader is tested without real videos.
@Suite struct MatroskaReaderTests {
    // MARK: Building files

    private static func element(_ id: UInt32, _ body: Data) -> Data {
        var data = Data()
        let idBytes = withUnsafeBytes(of: id.bigEndian, Array.init).drop { $0 == 0 }
        data.append(contentsOf: idBytes)
        // An eight-byte size: 0x01 then seven bytes, valid for any length.
        data.append(0x01)
        data.append(contentsOf: withUnsafeBytes(of: UInt64(body.count).bigEndian, Array.init).dropFirst())
        data.append(body)
        return data
    }

    private static func element(_ id: UInt32, _ children: [Data]) -> Data { element(id, children.reduce(Data(), +)) }
    private static func uint(_ id: UInt32, _ value: UInt64) -> Data {
        element(id, Data(withUnsafeBytes(of: value.bigEndian, Array.init).drop { $0 == 0 }.ifEmpty([0])))
    }
    private static func float(_ id: UInt32, _ value: Double) -> Data {
        element(id, Data(withUnsafeBytes(of: value.bitPattern.bigEndian, Array.init)))
    }
    private static func string(_ id: UInt32, _ value: String) -> Data { element(id, Data(value.utf8)) }

    /// A SimpleBlock: track number as a one-byte vint, a 16-bit time, flags, then the frame.
    private static func simpleBlock(track: UInt8, time: Int16, keyframe: Bool, _ frame: String) -> Data {
        var body = Data([0x80 | track])
        body.append(contentsOf: withUnsafeBytes(of: time.bigEndian, Array.init))
        body.append(keyframe ? 0x80 : 0x00)
        body.append(Data(frame.utf8))
        return element(0xA3, body)
    }

    /// A ten-second file with an H.264 track and an English AAC track, and one cluster of two blocks.
    static let sample: Data = {
        let header = element(0x1A45DFA3, [string(0x4282, "matroska")])
        let info = element(0x1549A966, [uint(0x2AD7B1, 1_000_000), float(0x4489, 10_000)])
        let video = element(0xAE, [uint(0xD7, 1), uint(0x83, 1), string(0x86, "V_MPEG4/ISO/AVC"),
                                   element(0xE0, [uint(0xB0, 1920), uint(0xBA, 1080)])])
        let audio = element(0xAE, [uint(0xD7, 2), uint(0x83, 2), string(0x86, "A_AAC"), string(0x22B59C, "eng"),
                                   element(0xE1, [float(0xB5, 48_000), uint(0x9F, 2)])])
        let tracks = element(0x1654AE6B, [video, audio])
        let cluster = element(0x1F43B675, [uint(0xE7, 0),
                                           simpleBlock(track: 1, time: 0, keyframe: true, "video-frame"),
                                           simpleBlock(track: 2, time: 21, keyframe: true, "audio-frame")])
        return header + element(0x18538067, [info, tracks, cluster])
    }()

    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mactv-\(UUID().uuidString).mkv")
        try data.write(to: url)
        return url
    }

    // MARK: Tests

    @Test func readsTracksAndDuration() throws {
        let url = try file(Self.sample)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try MatroskaReader(url: url)

        #expect(reader.duration == 10_000_000_000)
        #expect(reader.tracks.count == 2)
        let video = try #require(reader.tracks.first { $0.kind == .video })
        #expect(video.codec == "V_MPEG4/ISO/AVC")
        #expect(video.width == 1920 && video.height == 1080)
        let audio = try #require(reader.tracks.first { $0.kind == .audio })
        #expect(audio.codec == "A_AAC")
        #expect(audio.language == "eng")
        #expect(audio.sampleRate == 48_000 && audio.channels == 2)
    }

    @Test func readsBlocksInOrder() throws {
        let url = try file(Self.sample)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try MatroskaReader(url: url)

        let first = try #require(reader.nextBlock())
        #expect(first.track == 1 && first.time == 0 && first.keyframe)
        #expect(first.frames == [Data("video-frame".utf8)])
        let second = try #require(reader.nextBlock())
        #expect(second.track == 2 && second.time == 21_000_000)
        #expect(second.frames == [Data("audio-frame".utf8)])
        #expect(reader.nextBlock() == nil)
    }

    @Test func skipsTracksNotWanted() throws {
        let url = try file(Self.sample)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try MatroskaReader(url: url)
        reader.wanted = [2]

        #expect(reader.nextBlock()?.track == 2)
        #expect(reader.nextBlock() == nil)
    }

    @Test func rejectsFilesThatAreNotMatroska() throws {
        for data in [Data(), Data("not a video at all".utf8), Data(repeating: 0xFF, count: 64)] {
            let url = try file(data)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(throws: (any Error).self) { try MatroskaReader(url: url) }
        }
    }

    /// Cut the file at every length: opening either fails or works, and reading always ends.
    @Test func survivesFilesCutShortAnywhere() throws {
        for length in 0..<Self.sample.count {
            let url = try file(Self.sample.prefix(length))
            defer { try? FileManager.default.removeItem(at: url) }
            guard let reader = try? MatroskaReader(url: url) else { continue }
            var blocks = 0
            while reader.nextBlock() != nil, blocks < 10 { blocks += 1 }
            #expect(blocks <= 2)
        }
    }
}

private extension Sequence where Element == UInt8 {
    func ifEmpty(_ fallback: [UInt8]) -> [UInt8] {
        let bytes = Array(self)
        return bytes.isEmpty ? fallback : bytes
    }
}
