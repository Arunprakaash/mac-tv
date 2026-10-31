import Foundation

/// Reads Matroska (.mkv, and WebM) files: the tracks, the index for seeking, and the compressed
/// video, audio and subtitle frames in order. macOS can decode what's inside most MKV files
/// (H.264 or HEVC video, AAC or Dolby audio) but can't open the container itself; this does the
/// opening, and MatroskaPlayback hands the frames to macOS's own decoders. Nothing is converted.
///
/// Not thread-safe: use one reader from one queue.
final class MatroskaReader {
    struct Track {
        enum Kind { case video, audio, subtitle, other }

        let number: UInt64
        let kind: Kind
        let codec: String
        let codecPrivate: Data?
        let language: String
        let name: String?
        let isDefault: Bool
        let isForced: Bool
        /// Nanoseconds per frame, when the file says.
        let defaultDuration: UInt64?
        let width: Int, height: Int
        let displayWidth: Int?, displayHeight: Int?
        let sampleRate: Double
        let outputSampleRate: Double?
        let channels: Int
        let bitDepth: Int?
        /// Bytes the muxer stripped from the start of every frame ("header stripping").
        let strippedHeader: Data?
        /// Frames are zlib-compressed or encrypted; not supported.
        let unsupportedEncoding: Bool
    }

    /// A block of frames from one track: usually one video frame, or one or more audio frames.
    struct Block {
        let track: UInt64
        /// Presentation time in nanoseconds.
        let time: Int64
        let duration: Int64?
        let keyframe: Bool
        let frames: [Data]
    }

    struct Cue {
        let time: Int64
        let position: UInt64
    }

    enum Failure: Error { case notMatroska, truncated, malformed }

    private(set) var tracks: [Track] = []
    /// Nanoseconds; 0 when the file doesn't say.
    private(set) var duration: Int64 = 0
    private(set) var cues: [Cue] = []
    /// Only these tracks' blocks are read; others are skipped without loading.
    var wanted: Set<UInt64> = []

    private let source: ByteSource
    private var timecodeScale: UInt64 = 1_000_000
    private var segmentStart: UInt64 = 0
    private var segmentEnd: UInt64 = 0
    private var firstCluster: UInt64 = 0
    private var clusterTime: UInt64 = 0

    init(url: URL) throws {
        source = try ByteSource(url: url)
        try readHeaders()
        wanted = Set(tracks.map(\.number))
        source.position = firstCluster
    }

    var fileSize: UInt64 { source.size }

    // MARK: Headers

    private enum ID {
        static let ebml: UInt32 = 0x1A45DFA3, segment: UInt32 = 0x18538067
        static let seekHead: UInt32 = 0x114D9B74, seek: UInt32 = 0x4DBB, seekID: UInt32 = 0x53AB, seekPosition: UInt32 = 0x53AC
        static let info: UInt32 = 0x1549A966, timecodeScale: UInt32 = 0x2AD7B1, duration: UInt32 = 0x4489
        static let tracks: UInt32 = 0x1654AE6B, trackEntry: UInt32 = 0xAE
        static let cues: UInt32 = 0x1C53BB6B, cuePoint: UInt32 = 0xBB, cueTime: UInt32 = 0xB3
        static let cueTrackPositions: UInt32 = 0xB7, cueClusterPosition: UInt32 = 0xF1
        static let cluster: UInt32 = 0x1F43B675, timecode: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3, blockGroup: UInt32 = 0xA0, block: UInt32 = 0xA1
        static let blockDuration: UInt32 = 0x9B, referenceBlock: UInt32 = 0xFB
    }

    private func readHeaders() throws {
        source.position = 0
        let ebml = try readElementHeader()
        guard ebml.id == ID.ebml, let size = ebml.size else { throw Failure.notMatroska }
        source.position += size
        // Some files have padding (Void) before the segment.
        var segment = try readElementHeader()
        while segment.id != ID.segment {
            guard let size = segment.size else { throw Failure.notMatroska }
            source.position += size
            segment = try readElementHeader()
        }
        segmentStart = source.position
        segmentEnd = segment.size.map { min(segmentStart + $0, source.size) } ?? source.size

        var seeks: [UInt32: UInt64] = [:]
        var haveInfo = false, haveTracks = false, haveCues = false
        while source.position < segmentEnd {
            let start = source.position
            let element = try readElementHeader()
            if element.id == ID.cluster {
                firstCluster = start
                break
            }
            guard let size = element.size else { throw Failure.malformed }
            let end = source.position + size
            switch element.id {
            case ID.seekHead: seeks.merge(try readSeekHead(end: end)) { first, _ in first }
            case ID.info: try readInfo(end: end); haveInfo = true
            case ID.tracks: try readTracks(end: end); haveTracks = true
            case ID.cues: try readCues(end: end); haveCues = true
            default: break
            }
            source.position = end
        }
        guard firstCluster > 0 else { throw Failure.malformed }

        // The index and sometimes the track list come after the frames; the seek head says where.
        for (id, done) in [(ID.info, haveInfo), (ID.tracks, haveTracks), (ID.cues, haveCues)] where !done {
            guard let offset = seeks[id] else { continue }
            source.position = segmentStart + offset
            guard let element = try? readElementHeader(), element.id == id, let size = element.size else { continue }
            let end = source.position + size
            switch id {
            case ID.info: try? readInfo(end: end)
            case ID.tracks: try? readTracks(end: end)
            default: try? readCues(end: end)
            }
        }
        guard !tracks.isEmpty else { throw Failure.malformed }
    }

    private func readSeekHead(end: UInt64) throws -> [UInt32: UInt64] {
        var seeks: [UInt32: UInt64] = [:]
        try children(until: end) { id, size in
            guard id == ID.seek else { return false }
            var target: UInt32 = 0, position: UInt64?
            try children(until: source.position + size) { id, size in
                switch id {
                case ID.seekID: target = UInt32(truncatingIfNeeded: try readUInt(size))
                case ID.seekPosition: position = try readUInt(size)
                default: return false
                }
                return true
            }
            if let position { seeks[target] = position }
            return true
        }
        return seeks
    }

    private func readInfo(end: UInt64) throws {
        var rawDuration: Double?
        try children(until: end) { id, size in
            switch id {
            case ID.timecodeScale: timecodeScale = try readUInt(size)
            case ID.duration: rawDuration = try readFloat(size)
            default: return false
            }
            return true
        }
        if let rawDuration { duration = Int64(rawDuration * Double(timecodeScale)) }
    }

    private func readTracks(end: UInt64) throws {
        tracks = []
        try children(until: end) { id, size in
            guard id == ID.trackEntry else { return false }
            if let track = try readTrack(end: source.position + size) { tracks.append(track) }
            return true
        }
    }

    private func readTrack(end: UInt64) throws -> Track? {
        var number: UInt64 = 0, type: UInt64 = 0, codec = "", codecPrivate: Data?, language = "eng", bcp47: String?
        var name: String?, isDefault = true, isForced = false, defaultDuration: UInt64?
        var width = 0, height = 0, displayWidth: Int?, displayHeight: Int?
        var sampleRate = 8000.0, outputSampleRate: Double?, channels = 1, bitDepth: Int?
        var stripped: Data?, unsupported = false
        try children(until: end) { id, size in
            let childEnd = source.position + size
            switch id {
            case 0xD7: number = try readUInt(size)
            case 0x83: type = try readUInt(size)
            case 0x86: codec = try readString(size)
            case 0x63A2: codecPrivate = try source.read(Int(size))
            case 0x22B59C: language = try readString(size)
            case 0x22B59D: bcp47 = try readString(size)
            case 0x536E: name = try readString(size)
            case 0x88: isDefault = try readUInt(size) != 0
            case 0x55AA: isForced = try readUInt(size) != 0
            case 0x23E383: defaultDuration = try readUInt(size)
            case 0xE0:
                try children(until: childEnd) { id, size in
                    switch id {
                    case 0xB0: width = Int(try readUInt(size))
                    case 0xBA: height = Int(try readUInt(size))
                    case 0x54B0: displayWidth = Int(try readUInt(size))
                    case 0x54BA: displayHeight = Int(try readUInt(size))
                    default: return false
                    }
                    return true
                }
            case 0xE1:
                try children(until: childEnd) { id, size in
                    switch id {
                    case 0xB5: sampleRate = try readFloat(size)
                    case 0x78B5: outputSampleRate = try readFloat(size)
                    case 0x9F: channels = Int(try readUInt(size))
                    case 0x6264: bitDepth = Int(try readUInt(size))
                    default: return false
                    }
                    return true
                }
            case 0x6D80:
                // ContentEncodings › ContentEncoding › ContentCompression / ContentEncryption.
                try children(until: childEnd) { id, size in
                    guard id == 0x6240 else { return false }
                    try children(until: source.position + size) { id, size in
                        switch id {
                        case 0x5034:
                            var algorithm: UInt64 = 0
                            var settings: Data?
                            try children(until: source.position + size) { id, size in
                                switch id {
                                case 0x4254: algorithm = try readUInt(size)
                                case 0x4255: settings = try source.read(Int(size))
                                default: return false
                                }
                                return true
                            }
                            if algorithm == 3 { stripped = settings } else { unsupported = true }
                        case 0x5035: unsupported = true
                        default: return false
                        }
                        return true
                    }
                    return true
                }
            default: return false
            }
            return true
        }
        guard number > 0 else { return nil }
        let kind: Track.Kind = switch type {
        case 1: .video
        case 2: .audio
        case 17: .subtitle
        default: .other
        }
        return Track(number: number, kind: kind, codec: codec, codecPrivate: codecPrivate,
                     language: bcp47 ?? language, name: name, isDefault: isDefault, isForced: isForced,
                     defaultDuration: defaultDuration, width: width, height: height,
                     displayWidth: displayWidth, displayHeight: displayHeight,
                     sampleRate: sampleRate, outputSampleRate: outputSampleRate, channels: channels, bitDepth: bitDepth,
                     strippedHeader: stripped, unsupportedEncoding: unsupported)
    }

    private func readCues(end: UInt64) throws {
        var found: [Cue] = []
        try children(until: end) { id, size in
            guard id == ID.cuePoint else { return false }
            var time: UInt64 = 0, position: UInt64?
            try children(until: source.position + size) { id, size in
                switch id {
                case ID.cueTime: time = try readUInt(size)
                case ID.cueTrackPositions:
                    try children(until: source.position + size) { id, size in
                        guard id == ID.cueClusterPosition else { return false }
                        if position == nil { position = try readUInt(size) }
                        return true
                    }
                default: return false
                }
                return true
            }
            if let position {
                found.append(Cue(time: Int64(time * timecodeScale), position: segmentStart + position))
            }
            return true
        }
        cues = found.sorted { $0.time < $1.time }
    }

    // MARK: Frames

    /// The next block from a wanted track, or nil at the end of the file.
    func nextBlock() -> Block? {
        while source.position < segmentEnd {
            let start = source.position
            guard let element = try? readElementHeader() else {
                guard resync(from: start + 1) else { return nil }
                continue
            }
            switch element.id {
            case ID.cluster:
                // Step inside; a cluster's size may be unknown, so its children are read in line.
                clusterTime = 0
            case ID.timecode:
                guard let size = element.size, let time = try? readUInt(size) else { return nil }
                clusterTime = time
            case ID.simpleBlock:
                guard let size = element.size else { return nil }
                let end = source.position + size
                let block = try? readBlock(end: end, simple: true, duration: nil, referenced: false)
                source.position = end
                if let block { return block }
            case ID.blockGroup:
                guard let size = element.size else { return nil }
                let end = source.position + size
                var blockStart: UInt64?, blockEnd: UInt64 = 0, duration: UInt64?, referenced = false
                try? children(until: end) { id, size in
                    switch id {
                    case ID.block: blockStart = source.position; blockEnd = source.position + size
                    case ID.blockDuration: duration = try readUInt(size)
                    case ID.referenceBlock: referenced = true
                    default: return false
                    }
                    return true
                }
                var block: Block?
                if let blockStart {
                    source.position = blockStart
                    block = try? readBlock(end: blockEnd, simple: false,
                                           duration: duration.map { Int64($0 * timecodeScale) }, referenced: referenced)
                }
                source.position = end
                if let block { return block }
            default:
                // Other cluster children, and whatever follows the clusters (index, tags).
                guard let size = element.size else {
                    guard resync(from: start + 1) else { return nil }
                    continue
                }
                source.position += size
            }
        }
        return nil
    }

    private func readBlock(end: UInt64, simple: Bool, duration: Int64?, referenced: Bool) throws -> Block? {
        let trackNumber = try readVint(masked: true)
        guard wanted.contains(trackNumber), let track = tracks.first(where: { $0.number == trackNumber }) else { return nil }
        let header = try source.read(3)
        let relative = Int16(bitPattern: UInt16(header[header.startIndex]) << 8 | UInt16(header[header.startIndex + 1]))
        let flags = header[header.startIndex + 2]
        let keyframe = simple ? flags & 0x80 != 0 : !referenced
        let time = (Int64(clusterTime) + Int64(relative)) * Int64(timecodeScale)

        var sizes: [Int] = []
        let lacing = (flags >> 1) & 0x03
        if lacing != 0 {
            let count = Int(try source.byte()) + 1
            switch lacing {
            case 1: // Xiph
                for _ in 0..<(count - 1) {
                    var size = 0, byte: UInt8 = 255
                    while byte == 255 { byte = try source.byte(); size += Int(byte) }
                    sizes.append(size)
                }
            case 3: // EBML
                var size = Int(try readVint(masked: true))
                sizes.append(size)
                for _ in 1..<max(count - 1, 1) where count > 2 {
                    let (raw, length) = try readVintWithLength()
                    let bias = (1 << (7 * length - 1)) - 1
                    size += Int(raw) - bias
                    sizes.append(size)
                }
            default: // Fixed
                let total = Int(end - source.position)
                sizes = Array(repeating: total / count, count: count - 1)
            }
            let remaining = Int(end - source.position) - sizes.reduce(0, +)
            guard remaining >= 0 else { throw Failure.malformed }
            sizes.append(remaining)
        } else {
            sizes = [Int(end - source.position)]
        }
        var frames: [Data] = []
        frames.reserveCapacity(sizes.count)
        for size in sizes {
            var frame = try source.read(size)
            if let stripped = track.strippedHeader { frame = stripped + frame }
            frames.append(frame)
        }
        return Block(track: trackNumber, time: time, duration: duration, keyframe: keyframe, frames: frames)
    }

    // MARK: Seeking

    /// Moves to the cluster holding the last keyframe at or before `time` (nanoseconds).
    func seek(to time: Int64) {
        clusterTime = 0
        if let cue = cues.last(where: { $0.time <= time }) ?? cues.first {
            source.position = cue.position
            return
        }
        // No index: guess from the bit rate, then find the next cluster.
        guard duration > 0, time > 0 else { source.position = firstCluster; return }
        let fraction = max(0, min(1, Double(time) / Double(duration) - 0.01))
        let guess = firstCluster + UInt64(Double(segmentEnd - firstCluster) * fraction)
        if !resync(from: guess) { source.position = firstCluster }
    }

    /// Finds the next cluster at or after `position`, after damage or a guessed seek.
    @discardableResult
    private func resync(from position: UInt64) -> Bool {
        let pattern: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]
        var at = position
        while at + 4 <= segmentEnd {
            source.position = at
            guard let chunk = try? source.read(Int(min(1 << 20, segmentEnd - at))) else { return false }
            let bytes = [UInt8](chunk)
            if bytes.count >= 4 {
                for i in 0...(bytes.count - 4) where bytes[i] == pattern[0] && bytes[i + 1] == pattern[1]
                    && bytes[i + 2] == pattern[2] && bytes[i + 3] == pattern[3] {
                    source.position = at + UInt64(i)
                    clusterTime = 0
                    return true
                }
            }
            at += UInt64(max(bytes.count - 3, 1))
        }
        source.position = segmentEnd
        return false
    }

    // MARK: EBML

    private func readElementHeader() throws -> (id: UInt32, size: UInt64?) {
        let first = try source.byte()
        let length = first.leadingZeroBitCount + 1
        guard length <= 4 else { throw Failure.malformed }
        var id = UInt32(first)
        for _ in 1..<length { id = id << 8 | UInt32(try source.byte()) }
        let (size, sizeLength) = try readVintWithLength()
        let unknown = size == (UInt64(1) << (7 * UInt64(sizeLength))) - 1
        return (id, unknown ? nil : size)
    }

    private func readVint(masked: Bool) throws -> UInt64 {
        try readVintWithLength().value
    }

    private func readVintWithLength() throws -> (value: UInt64, length: Int) {
        let first = try source.byte()
        let length = first.leadingZeroBitCount + 1
        guard length <= 8 else { throw Failure.malformed }
        var value = UInt64(first) & (0xFF >> length)
        for _ in 1..<length { value = value << 8 | UInt64(try source.byte()) }
        return (value, length)
    }

    private func readUInt(_ size: UInt64) throws -> UInt64 {
        guard size <= 8 else { throw Failure.malformed }
        var value: UInt64 = 0
        for _ in 0..<size { value = value << 8 | UInt64(try source.byte()) }
        return value
    }

    private func readFloat(_ size: UInt64) throws -> Double {
        let bits = try readUInt(size)
        switch size {
        case 4: return Double(Float(bitPattern: UInt32(bits)))
        case 8: return Double(bitPattern: bits)
        default: return 0
        }
    }

    private func readString(_ size: UInt64) throws -> String {
        let data = try source.read(Int(size))
        return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Walks the child elements up to `end`. `handle` reads the element and returns true, or
    /// returns false to have it skipped.
    private func children(until end: UInt64, _ handle: (UInt32, UInt64) throws -> Bool) throws {
        while source.position < end {
            let element = try readElementHeader()
            guard let size = element.size else { throw Failure.malformed }
            let childEnd = source.position + size
            if !(try handle(element.id, size)) || source.position != childEnd { source.position = childEnd }
        }
    }
}

/// Buffered reads from a large file at any position.
private final class ByteSource {
    let size: UInt64
    var position: UInt64 = 0
    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private var bufferStart: UInt64 = 0
    private static let chunk = 1 << 20

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    private func fill(_ count: Int) throws {
        if position >= bufferStart, position + UInt64(count) <= bufferStart + UInt64(buffer.count) { return }
        guard position + UInt64(count) <= size else { throw MatroskaReader.Failure.truncated }
        try handle.seek(toOffset: position)
        let wanted = max(count, Self.chunk)
        buffer = [UInt8](try handle.read(upToCount: wanted) ?? Data())
        bufferStart = position
        guard buffer.count >= count else { throw MatroskaReader.Failure.truncated }
    }

    func byte() throws -> UInt8 {
        try fill(1)
        let value = buffer[Int(position - bufferStart)]
        position += 1
        return value
    }

    func read(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        try fill(count)
        let start = Int(position - bufferStart)
        position += UInt64(count)
        return Data(buffer[start..<(start + count)])
    }
}
