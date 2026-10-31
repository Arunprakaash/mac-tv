import AVFoundation
import SwiftUI

/// What plays a movie: AVFoundation for the files macOS opens itself (MP4, MOV, M4V), or
/// MatroskaPlayback for MKV. Used from the main thread.
protocol PlaybackEngine: AnyObject {
    var layer: CALayer { get }
    /// Seconds; 0 until known.
    var duration: Double { get }
    var currentTime: Double { get }
    var isPlaying: Bool { get }
    var ended: Bool { get }
    /// Set when the decoder gives up partway: "video" or "audio".
    var renderFailure: String? { get }
    var audioOptions: [MediaOption] { get }
    var subtitleOptions: [MediaOption] { get }
    var selectedAudio: Int? { get }
    var selectedSubtitle: Int? { get }
    func start(at seconds: Double)
    func play()
    func pause()
    func seek(to seconds: Double)
    func selectAudio(_ index: Int)
    func selectSubtitle(_ index: Int?)
    /// Subtitle text to draw now, for engines that don't draw their own.
    func subtitle(at seconds: Double) -> String?
    func stop()
}

enum PlaybackProblem: Error {
    case unreadable
    /// The codec, for the message.
    case unsupported(String)
}

/// An audio or subtitle track, as the player's menu shows it.
struct MediaOption: Hashable {
    let language: String
    let name: String?
    let detail: String?

    var title: String {
        let languageName = Self.languageCode(language).flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        // Release sites put their address where the track name goes.
        let name = name.flatMap { $0.range(of: #"[A-Za-z0-9-]+\.[A-Za-z]{2,}"#, options: .regularExpression) == nil ? $0 : nil }
        if let name, !name.isEmpty {
            // Track names often repeat the language; don't say it twice.
            if let languageName, !name.localizedCaseInsensitiveContains(languageName) { return "\(languageName) – \(name)" }
            return name
        }
        return languageName ?? (language == "und" ? "Unknown" : language)
    }

    var subtitle: String? { detail }

    /// "eng", "en" and "en-US" all become "en".
    static func languageCode(_ language: String) -> String? {
        guard !language.isEmpty, language != "und" else { return nil }
        let base = String(language.split(separator: "-").first ?? Substring(language))
        return Locale.LanguageCode(base).identifier(.alpha2) ?? base
    }

    /// Whether this is the language the Mac is set to.
    static func prefers(_ language: String) -> Bool {
        guard let code = languageCode(language) else { return false }
        return Locale.preferredLanguages.first.flatMap { languageCode($0) } == code
    }
}

/// One subtitle on screen from `start` to `end` seconds.
struct SubtitleCue {
    let start: Double
    let end: Double
    let text: String

    static func isText(codec: String) -> Bool {
        ["S_TEXT/UTF8", "S_TEXT/ASS", "S_TEXT/SSA", "S_TEXT/WEBVTT", "S_ASS", "S_SSA"].contains(codec)
    }

    /// The words in an MKV subtitle frame, without styling.
    static func text(from data: Data, codec: String) -> String? {
        var text = String(decoding: data, as: UTF8.self)
        if codec.contains("ASS") || codec.contains("SSA") {
            // ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            let fields = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9 else { return nil }
            text = String(fields[8]).replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        }
        return clean(text)
    }

    /// Drops HTML-style tags (<i>, <font>) and spare whitespace.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads an .srt or .vtt file.
    static func parse(file: URL) -> [SubtitleCue] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        var cues: [SubtitleCue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]), let end = seconds(parts[1]) else { continue }
            let words = clean(lines[(timing + 1)...].joined(separator: "\n"))
            if !words.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: words)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "01:02:03,450" or "02:03.450".
    private static func seconds(_ text: String) -> Double? {
        let stamp = text.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let fields = stamp.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
        guard (2...3).contains(fields.count) else { return nil }
        return fields.reduce(0) { $0 * 60 + $1 }
    }
}

/// Plays what AVFoundation can open. It draws the file's own subtitles itself.
final class AVPlayback: NSObject, PlaybackEngine {
    private let player: AVPlayer
    private let playerLayer: AVPlayerLayer
    private let audible: AVMediaSelectionGroup?
    private let legible: AVMediaSelectionGroup?
    private var endObserver: NSObjectProtocol?
    var layer: CALayer { playerLayer }
    let duration: Double
    let audioOptions: [MediaOption]
    let subtitleOptions: [MediaOption]
    private(set) var selectedAudio: Int?
    private(set) var selectedSubtitle: Int?
    private(set) var ended = false

    static func open(_ url: URL) async -> Result<AVPlayback, PlaybackProblem> {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return .failure(.unsupported(url.pathExtension.uppercased())) }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
        let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
        return .success(await MainActor.run {
            AVPlayback(item: AVPlayerItem(asset: asset), duration: duration.isFinite ? duration : 0, audible: audible, legible: legible)
        })
    }

    private init(item: AVPlayerItem, duration: Double, audible: AVMediaSelectionGroup?, legible: AVMediaSelectionGroup?) {
        player = AVPlayer(playerItem: item)
        playerLayer = AVPlayerLayer(player: player)
        self.duration = duration
        self.audible = audible
        // Forced-only tracks show on their own when needed; the menu offers full subtitles.
        let legibleOptions = legible?.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) } ?? []
        self.legible = legible
        // AVFoundation's display names are just the language ("English", "Unknown language").
        audioOptions = (audible?.options ?? []).map { MediaOption(language: $0.extendedLanguageTag ?? "und", name: nil, detail: nil) }
        subtitleOptions = legibleOptions.map { MediaOption(language: $0.extendedLanguageTag ?? "und", name: nil, detail: nil) }
        super.init()
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = CGColor.black
        player.appliesMediaSelectionCriteriaAutomatically = false
        if let audible, let current = item.currentMediaSelection.selectedMediaOption(in: audible) {
            selectedAudio = audible.options.firstIndex(of: current)
        }
        if let legible { item.select(nil, in: legible) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                             queue: .main) { [weak self] _ in self?.ended = true }
    }

    deinit { endObserver.map(NotificationCenter.default.removeObserver) }

    var currentTime: Double { max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0) }
    var isPlaying: Bool { player.rate != 0 }
    var renderFailure: String? { player.currentItem?.status == .failed ? "video" : nil }

    func start(at seconds: Double) {
        if seconds > 0 { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        player.play()
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration - 1 : seconds))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func selectAudio(_ index: Int) {
        guard let audible, audible.options.indices.contains(index) else { return }
        player.currentItem?.select(audible.options[index], in: audible)
        selectedAudio = index
    }

    func selectSubtitle(_ index: Int?) {
        guard let legible else { return }
        let options = legible.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        let option = index.flatMap { options.indices.contains($0) ? options[$0] : nil }
        player.currentItem?.select(option, in: legible)
        selectedSubtitle = option == nil ? nil : index
    }

    func subtitle(at seconds: Double) -> String? { nil }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// A frame from about `fraction` of the way in, for a movie without a poster.
    static func frame(of url: URL, at fraction: Double) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        return try? await generator.image(at: CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600)).image
    }
}

/// A movie playing on the TV: the engine, the on-screen controls and the audio and subtitle menu.
@MainActor
final class MoviePlayer: ObservableObject {
    /// The audio and subtitle menu, opened by moving down.
    struct Menu: Equatable {
        /// 0 audio, 1 subtitles.
        var column: Int
        var row: Int
    }

    let movie: Movie
    let engine: PlaybackEngine
    @Published private(set) var time: Double = 0
    @Published private(set) var playing = true
    @Published private(set) var controlsVisible = true
    @Published private(set) var subtitleText: String?
    @Published var menu: Menu?
    /// The control the remote just used ("back", "playpause", "forward"), lit for a moment.
    @Published private(set) var pressed: String?

    /// Subtitle files next to the movie (Movie.srt, Movie.en.srt).
    private let sidecars: [(option: MediaOption, cues: [SubtitleCue])]
    /// Index into `subtitleOptions`; nil is off.
    @Published private(set) var selectedSubtitle: Int?
    private var tick: Timer?
    private var hideAt = Date().addingTimeInterval(4)
    private var pressTask: Task<Void, Never>?
    private var lastSaved = Date()
    var onEnd: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onClose: (() -> Void)?

    init(movie: Movie, engine: PlaybackEngine) {
        self.movie = movie
        self.engine = engine
        sidecars = Self.findSidecars(for: movie.url)
        if engine.subtitleOptions.isEmpty, let first = sidecars.firstIndex(where: { MediaOption.prefers($0.option.language) }) {
            // A subtitle file sitting next to the movie in your language was put there to be used.
            selectedSubtitle = first
        }
    }

    var duration: Double { engine.duration > 0 ? engine.duration : (movie.duration ?? 0) }
    var audioOptions: [MediaOption] { engine.audioOptions }
    var subtitleOptions: [MediaOption] { engine.subtitleOptions + sidecars.map(\.option) }
    var selectedAudio: Int? { engine.selectedAudio }
    var hasMenu: Bool { audioOptions.count > 1 || !subtitleOptions.isEmpty }

    func start(at seconds: Double) {
        engine.start(at: seconds)
        time = seconds
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func update() {
        time = engine.currentTime
        if let index = selectedSubtitle, index >= engine.subtitleOptions.count {
            let cues = sidecars[index - engine.subtitleOptions.count].cues
            subtitleText = cues.last { $0.start <= time && time < $0.end }?.text
        } else {
            subtitleText = engine.subtitle(at: time)
        }
        if controlsVisible, playing, menu == nil, Date() > hideAt {
            withAnimation(Motion.appear) { controlsVisible = false }
        }
        if let failure = engine.renderFailure {
            tick?.invalidate()
            onFailure?(failure)
        } else if engine.ended {
            tick?.invalidate()
            onEnd?()
        } else if playing, Date().timeIntervalSince(lastSaved) > 10 {
            save()
        }
    }

    func save() {
        lastSaved = Date()
        MovieLibrary.shared.record(position: engine.currentTime, duration: duration, for: movie)
    }

    func stop() {
        tick?.invalidate()
        save()
        engine.stop()
    }

    // MARK: Remote

    func showControls() {
        hideAt = Date().addingTimeInterval(4)
        if !controlsVisible { withAnimation(Motion.appear) { controlsVisible = true } }
    }

    private var lastPointer: CGPoint?

    /// The mouse moving shows the controls. Remote presses hide the cursor, which reports a hover
    /// at the same spot; that doesn't count.
    func pointerMoved(to point: CGPoint) {
        defer { lastPointer = point }
        guard let last = lastPointer, abs(last.x - point.x) + abs(last.y - point.y) > 3 else { return }
        showControls()
    }

    func togglePlayback() {
        playing.toggle()
        playing ? engine.play() : engine.pause()
        light("playpause")
        showControls()
        if !playing { save() }
    }

    func skip(_ seconds: Double) {
        engine.seek(to: engine.currentTime + seconds)
        time = max(0, min(duration, time + seconds))
        light(seconds > 0 ? "forward" : "back")
        showControls()
    }

    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        let target = max(0, min(1, fraction)) * duration
        engine.seek(to: target)
        time = target
        showControls()
    }

    private func light(_ control: String) {
        pressed = control
        pressTask?.cancel()
        pressTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.35))
            if !Task.isCancelled { self?.pressed = nil }
        }
    }

    /// The menu's columns: audio (when there's a choice) and subtitles (Off first).
    var menuColumns: [[String]] {
        var columns: [[String]] = []
        if audioOptions.count > 1 { columns.append(audioOptions.map(\.title)) }
        columns.append(["Off"] + subtitleOptions.map(\.title))
        return columns
    }

    private var audioColumnShown: Bool { audioOptions.count > 1 }

    /// Whether the open menu is on subtitles.
    var menuShowsSubtitles: Bool {
        guard let menu else { return false }
        return !audioColumnShown || menu.column == 1
    }

    /// The subtitle or audio button: opens the menu on that column, or closes it.
    func toggleMenu(subtitles: Bool) {
        let column = subtitles && audioColumnShown ? 1 : 0
        if menu?.column == column { menu = nil; showControls(); return }
        menu = Menu(column: column, row: selectedRow(in: column))
        showControls()
    }

    /// A click on a menu row.
    func choose(column: Int, row: Int) {
        menu = Menu(column: column, row: row)
        chooseInMenu()
    }

    func openMenu() {
        guard hasMenu else { showControls(); return }
        let column = 0
        menu = Menu(column: column, row: selectedRow(in: column))
        showControls()
    }

    /// The ticked row in a menu column.
    func selectedRow(in column: Int) -> Int {
        if audioColumnShown && column == 0 { return selectedAudio ?? 0 }
        return selectedSubtitle.map { $0 + 1 } ?? 0
    }

    func moveInMenu(_ direction: RemoteCommand.Direction) {
        guard var menu else { return }
        let columns = menuColumns
        switch direction {
        case .left: menu.column = max(0, menu.column - 1)
        case .right: menu.column = min(columns.count - 1, menu.column + 1)
        case .up:
            if menu.row == 0 { self.menu = nil; return }
            menu.row -= 1
        case .down: menu.row = min(columns[menu.column].count - 1, menu.row + 1)
        }
        if direction == .left || direction == .right { menu.row = selectedRow(in: menu.column) }
        self.menu = menu
        showControls()
    }

    func chooseInMenu() {
        guard let menu else { return }
        if audioColumnShown && menu.column == 0 {
            engine.selectAudio(menu.row)
        } else {
            let choice = menu.row == 0 ? nil : menu.row - 1
            selectedSubtitle = choice
            let embedded = engine.subtitleOptions.count
            engine.selectSubtitle(choice.flatMap { $0 < embedded ? $0 : nil })
        }
        objectWillChange.send()
        showControls()
    }

    // MARK: Sidecar subtitles

    private static func findSidecars(for movie: URL) -> [(option: MediaOption, cues: [SubtitleCue])] {
        let folder = movie.deletingLastPathComponent()
        let base = movie.deletingPathExtension().lastPathComponent
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { ["srt", "vtt"].contains($0.pathExtension.lowercased()) && $0.lastPathComponent.hasPrefix(base) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file in
                // Movie.en.srt → "en"; Movie.srt → no language.
                let middle = file.deletingPathExtension().lastPathComponent.dropFirst(base.count)
                let language = middle.split(separator: ".").last.map(String.init) ?? "und"
                let cues = SubtitleCue.parse(file: file)
                guard !cues.isEmpty else { return nil }
                let known = MediaOption.languageCode(language).flatMap { Locale.current.localizedString(forLanguageCode: $0) } != nil
                return (MediaOption(language: known ? language : "und", name: known ? nil : "Subtitles file", detail: nil), cues)
            }
    }
}
