import AppKit
import AVFoundation
import Testing
@testable import MacTV

/// A film plays over the Movies browser it started from. The browser is opaque, so it must not be
/// drawn while the film plays (0.23–0.25 drew it on top, hiding every film).
@Suite @MainActor struct MoviePlayerLayerTests {
    @Test func theMoviesScreenIsHiddenWhileAFilmPlays() async throws {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Film.mp4")
        try await Self.writeOneSecondMovie(to: file)

        let tv = TVController(library: AppLibrary(folder: folder))
        tv.openMoviesBrowserOnly()
        #expect(RootView.showsMoviesScreen(tv))

        tv.playMovie(Movie(path: file.path, title: "Film", added: .now, size: 1), from: 0)
        for _ in 0..<200 where tv.moviePlayer == nil { try await Task.sleep(for: .milliseconds(25)) }
        defer { tv.goHome() }
        #expect(tv.moviePlayer != nil)
        #expect(tv.mode == .movie)
        // The browser is still open underneath, ready for when the film ends, but not drawn.
        #expect(tv.movies != nil)
        #expect(!RootView.showsMoviesScreen(tv))
    }

    /// One second of black, H.264 in MP4.
    private static func writeOneSecondMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer)
            guard let buffer else { continue }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
