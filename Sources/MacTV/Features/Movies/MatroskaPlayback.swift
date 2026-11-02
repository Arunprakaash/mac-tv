import AVFoundation
import AudioToolbox
import CoreMedia
import VideoToolbox

/// Plays an MKV file with macOS's own decoders: MatroskaReader pulls the frames out and they go
/// straight to a sample-buffer video layer and audio renderer, kept in step by one clock.
final class MatroskaPlayback: NSObject, PlaybackEngine {
    let videoLayer = AVSampleBufferDisplayLayer()
    var layer: CALayer { videoLayer }
    private(set) var duration: Double
    private(set) var failure: String?
    private(set) var isPlaying = false
    let audioOptions: [MediaOption]
    let subtitleOptions: [MediaOption]
    private(set) var selectedAudio: Int?
    private(set) var selectedSubtitle: Int?

    private let reader: MatroskaReader
    private let video: MatroskaReader.Track
    private let videoFormat: CMVideoFormatDescription
    private let audioTracks: [(track: MatroskaReader.Track, format: CMAudioFormatDescription)]
    private let subtitleTracks: [MatroskaReader.Track]
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let clock = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "Mac TV movie", qos: .userInitiated)

    // Touched only on `queue`.
    private var audio: (track: MatroskaReader.Track, format: CMAudioFormatDescription)?
    private var subtitle: MatroskaReader.Track?
    private var pendingVideo: [MatroskaReader.Block] = []
    private var pendingAudio: [MatroskaReader.Block] = []
    private var reachedEnd = false
    private var lastTime: Int64 = 0
    private var hideBefore: Int64 = .min

    private let cueLock = NSLock()
    private var cues: [SubtitleCue] = []
    private var endedFlag = false

    /// Opens the file, or says why it can't play here (another app can take it).
    static func open(_ url: URL) -> Result<MatroskaPlayback, PlaybackProblem> {
        guard let reader = try? MatroskaReader(url: url) else { return .failure(.unreadable) }
        guard let video = reader.tracks.first(where: { $0.kind == .video }) else { return .failure(.unsupported("no video")) }
        guard !video.unsupportedEncoding, let videoFormat = videoFormat(for: video) else {
            return .failure(.unsupported(video.codec))
        }
        let audio = reader.tracks.filter { $0.kind == .audio && !$0.unsupportedEncoding }
            .compactMap { track in audioFormat(for: track).map { (track, $0) } }
        if audio.isEmpty, reader.tracks.contains(where: { $0.kind == .audio }) {
            return .failure(.unsupported(reader.tracks.first { $0.kind == .audio }?.codec ?? "audio"))
        }
        let subtitles = reader.tracks.filter { $0.kind == .subtitle && SubtitleCue.isText(codec: $0.codec) }
        return .success(MatroskaPlayback(reader: reader, video: video, videoFormat: videoFormat, audio: audio, subtitles: subtitles))
    }

    private init(reader: MatroskaReader, video: MatroskaReader.Track, videoFormat: CMVideoFormatDescription,
                 audio: [(MatroskaReader.Track, CMAudioFormatDescription)], subtitles: [MatroskaReader.Track]) {
        self.reader = reader
        self.video = video
        self.videoFormat = videoFormat
        audioTracks = audio
        subtitleTracks = subtitles
        duration = Double(reader.duration) / 1e9
        audioOptions = audio.map { MediaOption(language: $0.0.language, name: $0.0.name, detail: Self.audioDetail($0.0)) }
        subtitleOptions = subtitles.map { MediaOption(language: $0.language, name: $0.name, detail: $0.isForced ? "Forced" : nil) }
        let preferred = audio.firstIndex { MediaOption.prefers($0.0.language) } ?? audio.firstIndex { $0.0.isDefault } ?? 0
        selectedAudio = audio.isEmpty ? nil : preferred
        self.audio = audio.isEmpty ? nil : audio[preferred]
        super.init()
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = CGColor.black
        clock.addRenderer(videoLayer.sampleBufferRenderer)
        clock.addRenderer(audioRenderer)
        reader.wanted = wantedTracks()
    }

    // MARK: PlaybackEngine

    var currentTime: Double { max(0, clock.currentTime().seconds) }
    var ended: Bool { queue.sync { endedFlag } }

    func start(at seconds: Double) {
        reposition(to: seconds, rate: 1)
        isPlaying = true
    }

    func play() {
        isPlaying = true
        clock.setRate(1, time: clock.currentTime())
    }

    func pause() {
        isPlaying = false
        clock.setRate(0, time: clock.currentTime())
    }

    func seek(to seconds: Double) {
        reposition(to: max(0, min(seconds, duration > 0 ? duration - 1 : seconds)), rate: isPlaying ? 1 : 0)
    }

    func selectAudio(_ index: Int) {
        guard audioTracks.indices.contains(index), index != selectedAudio else { return }
        selectedAudio = index
        let now = currentTime
        queue.async { [self] in
            audio = audioTracks[index]
            reader.wanted = wantedTracks()
        }
        reposition(to: now, rate: isPlaying ? 1 : 0)
    }

    func selectSubtitle(_ index: Int?) {
        selectedSubtitle = index.flatMap { subtitleTracks.indices.contains($0) ? $0 : nil }
        let now = currentTime
        queue.async { [self] in
            subtitle = selectedSubtitle.map { subtitleTracks[$0] }
            reader.wanted = wantedTracks()
        }
        // The subtitle frames already passed; go back over them.
        reposition(to: now, rate: isPlaying ? 1 : 0)
    }

    func subtitle(at seconds: Double) -> String? {
        cueLock.lock()
        defer { cueLock.unlock() }
        return cues.last { $0.start <= seconds && seconds < $0.end }?.text
    }

    func stop() {
        clock.setRate(0, time: .zero)
        queue.sync {
            videoLayer.sampleBufferRenderer.stopRequestingMediaData()
            audioRenderer.stopRequestingMediaData()
            videoLayer.sampleBufferRenderer.flush()
            audioRenderer.flush()
        }
    }

    var renderFailure: String? {
        if videoLayer.sampleBufferRenderer.status == .failed { return "video" }
        if audioRenderer.status == .failed { return "audio" }
        return nil
    }

    // MARK: Feeding the decoders

    private func wantedTracks() -> Set<UInt64> {
        var wanted: Set<UInt64> = [video.number]
        if let audio { wanted.insert(audio.track.number) }
        if let subtitle { wanted.insert(subtitle.number) }
        return wanted
    }

    /// Flushes everything, starts reading from the keyframe before `seconds`, fills the decoders,
    /// then starts the clock at `seconds`. Frames before it are decoded but not shown.
    private func reposition(to seconds: Double, rate: Float) {
        let target = Int64(seconds * 1e9)
        let time = CMTime(value: target, timescale: 1_000_000_000)
        clock.setRate(0, time: time)
        queue.async { [self] in
            let renderer = videoLayer.sampleBufferRenderer
            renderer.stopRequestingMediaData()
            audioRenderer.stopRequestingMediaData()
            renderer.flush()
            audioRenderer.flush()
            pendingVideo = []
            pendingAudio = []
            reachedEnd = false
            endedFlag = false
            cueLock.lock(); cues = []; cueLock.unlock()
            reader.seek(to: target)
            hideBefore = target - 60_000_000
            feedVideo()
            feedAudio()
            renderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feedVideo() }
            if audio != nil {
                audioRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feedAudio() }
            }
            DispatchQueue.main.async { self.clock.setRate(rate, time: time) }
        }
    }

    private func next(for track: UInt64) -> MatroskaReader.Block? {
        if track == video.number, !pendingVideo.isEmpty { return pendingVideo.removeFirst() }
        if track == audio?.track.number, !pendingAudio.isEmpty { return pendingAudio.removeFirst() }
        while let block = reader.nextBlock() {
            lastTime = max(lastTime, block.time)
            if block.track == track { return block }
            if block.track == video.number {
                pendingVideo.append(block)
            } else if block.track == audio?.track.number {
                pendingAudio.append(block)
            } else if block.track == subtitle?.number {
                addCue(block)
            }
        }
        reachedEnd = true
        return nil
    }

    private func feedVideo() {
        let renderer = videoLayer.sampleBufferRenderer
        while renderer.isReadyForMoreMediaData {
            guard let block = next(for: video.number) else {
                renderer.stopRequestingMediaData()
                checkEnd()
                return
            }
            let step = Int64(video.defaultDuration ?? 0)
            for (index, frame) in block.frames.enumerated() {
                let pts = block.time + Int64(index) * step
                if let sample = Self.sample(frame, format: videoFormat, pts: pts, keyframe: block.keyframe, hidden: pts < hideBefore) {
                    renderer.enqueue(sample)
                }
            }
        }
    }

    private func feedAudio() {
        guard let audio else { return }
        while audioRenderer.isReadyForMoreMediaData {
            guard let block = next(for: audio.track.number) else {
                audioRenderer.stopRequestingMediaData()
                checkEnd()
                return
            }
            if block.time + 50_000_000 < hideBefore { continue }
            if let sample = Self.audioSample(block.frames, format: audio.format, pts: block.time) {
                audioRenderer.enqueue(sample)
            }
        }
    }

    private func checkEnd() {
        guard reachedEnd else { return }
        // The last frames are queued; the movie ends when the clock passes them.
        let last = Double(lastTime) / 1e9
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.watchForEnd(last) }
    }

    private func watchForEnd(_ last: Double) {
        if currentTime >= last - 0.2 || !isPlaying && currentTime >= last - 1 {
            queue.async { self.endedFlag = true }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.watchForEnd(last) }
        }
    }

    private func addCue(_ block: MatroskaReader.Block) {
        guard let subtitle, let data = block.frames.first,
              let text = SubtitleCue.text(from: data, codec: subtitle.codec), !text.isEmpty else { return }
        let start = Double(block.time) / 1e9
        let end = start + Double(block.duration ?? 4_000_000_000) / 1e9
        cueLock.lock()
        cues.append(SubtitleCue(start: start, end: end, text: text))
        if cues.count > 200 { cues.removeFirst(cues.count - 200) }
        cueLock.unlock()
    }

    // MARK: Sample buffers

    private static func blockBuffer(_ data: Data) -> CMBlockBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        return copied == noErr ? block : nil
    }

    static func sample(_ data: Data, format: CMFormatDescription, pts: Int64, keyframe: Bool, hidden: Bool) -> CMSampleBuffer? {
        guard !data.isEmpty, let block = blockBuffer(data) else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            if !keyframe {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if hidden {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }

    private static func audioSample(_ frames: [Data], format: CMAudioFormatDescription, pts: Int64) -> CMSampleBuffer? {
        let data = frames.reduce(into: Data()) { $0.append($1) }
        guard !data.isEmpty, let block = blockBuffer(data) else { return nil }
        var offset: Int64 = 0
        let packets = frames.map { frame -> AudioStreamPacketDescription in
            defer { offset += Int64(frame.count) }
            return AudioStreamPacketDescription(mStartOffset: offset, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))
        }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames.count,
            presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000_000), packetDescriptions: packets,
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    // MARK: Formats

    static func videoFormat(for track: MatroskaReader.Track) -> CMVideoFormatDescription? {
        guard let config = track.codecPrivate, config.count > 4 else { return nil }
        let codec: CMVideoCodecType, atom: String
        switch track.codec {
        case "V_MPEG4/ISO/AVC":
            // 10-bit and 4:2:2/4:4:4 H.264 have no hardware decoder on the Mac.
            guard ![110, 122, 244].contains(config[config.startIndex + 1]) else { return nil }
            codec = kCMVideoCodecType_H264; atom = "avcC"
        case "V_MPEGH/ISO/HEVC":
            codec = kCMVideoCodecType_HEVC; atom = "hvcC"
        default:
            return nil
        }
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atom: config],
        ]
        if let displayWidth = track.displayWidth, let displayHeight = track.displayHeight, track.width > 0, track.height > 0,
           displayWidth * track.height != displayHeight * track.width {
            extensions[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: displayWidth * track.height,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: displayHeight * track.width,
            ]
        }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec,
                                             width: Int32(track.width), height: Int32(track.height),
                                             extensions: extensions as CFDictionary, formatDescriptionOut: &format) == noErr
        else { return nil }
        return format
    }

    static func audioFormat(for track: MatroskaReader.Track) -> CMAudioFormatDescription? {
        var description = AudioStreamBasicDescription(
            mSampleRate: track.sampleRate, mFormatID: 0, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(max(track.channels, 1)), mBitsPerChannel: 0, mReserved: 0)
        var cookie: Data?
        switch track.codec {
        case let codec where codec.hasPrefix("A_AAC"):
            let config = track.codecPrivate ?? aacConfig(sampleRate: track.sampleRate, channels: track.channels,
                                                         sbr: codec.hasSuffix("SBR"))
            description.mFormatID = kAudioFormatMPEG4AAC
            description.mFramesPerPacket = 1024
            cookie = esds(config)
        case "A_AC3":
            description.mFormatID = kAudioFormatAC3
            description.mFramesPerPacket = 1536
        case "A_EAC3":
            description.mFormatID = kAudioFormatEnhancedAC3
            description.mFramesPerPacket = 1536
        case "A_MPEG/L3":
            description.mFormatID = kAudioFormatMPEGLayer3
            description.mFramesPerPacket = 1152
        case "A_MPEG/L2":
            description.mFormatID = kAudioFormatMPEGLayer2
            description.mFramesPerPacket = 1152
        case "A_OPUS":
            description.mFormatID = kAudioFormatOpus
            description.mSampleRate = 48000
            description.mFramesPerPacket = 960
            cookie = track.codecPrivate
        default:
            return nil
        }
        var format: CMAudioFormatDescription?
        let status: OSStatus
        if let cookie {
            status = cookie.withUnsafeBytes { bytes in
                CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                                               magicCookieSize: cookie.count, magicCookie: bytes.baseAddress,
                                               extensions: nil, formatDescriptionOut: &format)
            }
        } else {
            status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    /// An AAC AudioSpecificConfig, for old files that leave it out.
    private static func aacConfig(sampleRate: Double, channels: Int, sbr: Bool) -> Data {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let index = UInt16(rates.firstIndex(of: sbr ? sampleRate / 2 : sampleRate) ?? 4)
        let objectType: UInt16 = 2
        let value = objectType << 11 | index << 7 | UInt16(channels & 0x0F) << 3
        return Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// The AAC decoder's cookie: an MPEG-4 elementary stream descriptor wrapping the config.
    private static func esds(_ config: Data) -> Data {
        func descriptor(_ tag: UInt8, _ body: Data) -> Data {
            Data([tag, 0x80, 0x80, 0x80, UInt8(body.count)]) + body
        }
        let specific = descriptor(0x05, config)
        let decoderConfig = descriptor(0x04, Data([0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) + specific)
        let sl = descriptor(0x06, Data([0x02]))
        return descriptor(0x03, Data([0, 0, 0]) + decoderConfig + sl)
    }

    private static func audioDetail(_ track: MatroskaReader.Track) -> String {
        let codec = switch track.codec {
        case let c where c.hasPrefix("A_AAC"): "AAC"
        case "A_AC3": "Dolby Digital"
        case "A_EAC3": "Dolby Digital Plus"
        case "A_OPUS": "Opus"
        default: "MP3"
        }
        let channels = switch track.channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(track.channels) channels"
        }
        return "\(codec) \(channels)"
    }

    // MARK: Still frames

    /// A frame from about `fraction` of the way in, for a movie without a poster.
    static func frame(of url: URL, at fraction: Double) -> CGImage? {
        guard let reader = try? MatroskaReader(url: url),
              let video = reader.tracks.first(where: { $0.kind == .video }),
              let format = videoFormat(for: video) else { return nil }
        reader.wanted = [video.number]
        reader.seek(to: Int64(Double(reader.duration) * fraction))
        var keyframe: MatroskaReader.Block?
        for _ in 0..<600 {
            guard let block = reader.nextBlock() else { break }
            if block.keyframe { keyframe = block; break }
        }
        guard let data = keyframe?.frames.first,
              let sample = sample(data, format: format, pts: keyframe!.time, keyframe: true, hidden: false) else { return nil }
        var session: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attributes, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr, let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }
        var image: CGImage?
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            guard status == noErr, let buffer else { return }
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return image
    }
}
