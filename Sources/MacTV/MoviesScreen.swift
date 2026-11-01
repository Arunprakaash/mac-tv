import AppKit
import SwiftUI

/// The Movies app's screen: Continue Watching, then every movie in the chosen folders as
/// posters, driven by the D-pad like the rest of the TV.
struct MoviesBrowser: Equatable {
    var row = 0
    var column = 0
    /// The Folders sheet, and its focused row.
    var folderRow: Int?
    /// Adding a network share, over the Folders sheet.
    var shareForm: ShareForm?
    /// Asking Resume or Start Over for this movie; 0 resume, 1 from the beginning.
    var resuming: String?
    var resumeRow = 0
}

/// The TV's Add Network Share form, typed with the keyboard or the phone's Type on TV.
struct ShareForm: Equatable {
    /// 0 address, 1 user name, 2 password, 3 Connect.
    var row = 0
    var address = ""
    var user = ""
    var password = ""
    var message: String?
    var failed = false
    var connecting = false
}

enum MovieItem: Hashable {
    case movie(String)
    case folders
}

struct MovieRow: Hashable {
    let title: String?
    let items: [MovieItem]
    var progress = false
}

extension TVController {
    static let movieColumns = 7

    var movieRows: [MovieRow] {
        let library = MovieLibrary.shared
        var rows: [MovieRow] = []
        let started = library.continueWatching.prefix(Self.movieColumns)
        if !started.isEmpty {
            rows.append(MovieRow(title: "Continue Watching", items: started.map { .movie($0.path) }, progress: true))
        }
        let all = library.movies.map { MovieItem.movie($0.path) } + [.folders]
        for start in stride(from: 0, to: all.count, by: Self.movieColumns) {
            let chunk = Array(all[start..<min(start + Self.movieColumns, all.count)])
            rows.append(MovieRow(title: start == 0 && !library.movies.isEmpty ? "Library" : nil, items: chunk))
        }
        return rows
    }

    /// The browser's focus, kept inside the rows as they change.
    var movieFocus: (row: Int, column: Int) {
        let rows = movieRows
        let browser = movies ?? MoviesBrowser()
        let row = min(browser.row, rows.count - 1)
        return (row, min(browser.column, rows[row].items.count - 1))
    }

    var focusedMovieItem: MovieItem {
        let focus = movieFocus
        return movieRows[focus.row].items[focus.column]
    }

    func openMovies() {
        movies = MoviesBrowser()
        MovieLibrary.shared.refresh()
    }

    func handleMovies(_ command: RemoteCommand) {
        guard var browser = movies else { return }
        if browser.shareForm != nil { handleShareForm(command); return }
        if browser.folderRow != nil { handleFolders(command); return }
        if let path = browser.resuming {
            switch command {
            case .move(.up): browser.resumeRow = 0
            case .move(.down): browser.resumeRow = 1
            case .back: browser.resuming = nil
            case .select, .playPause:
                movies?.resuming = nil
                if let movie = MovieLibrary.shared.movie(path) {
                    playMovie(movie, from: browser.resumeRow == 0 ? max(0, (movie.position ?? 0) - 5) : 0)
                }
                return
            default: break
            }
            movies = browser
            return
        }
        let rows = movieRows
        let focus = movieFocus
        browser.row = focus.row
        browser.column = focus.column
        switch command {
        case .back:
            movies = nil
            return
        case .move(.left): browser.column = max(0, focus.column - 1)
        case .move(.right): browser.column = min(rows[focus.row].items.count - 1, focus.column + 1)
        case .move(.up):
            if focus.row > 0 {
                browser.row -= 1
                browser.column = min(browser.column, rows[browser.row].items.count - 1)
            }
        case .move(.down):
            if focus.row < rows.count - 1 {
                browser.row += 1
                browser.column = min(browser.column, rows[browser.row].items.count - 1)
            }
        case .select, .playPause:
            movies = browser
            activateMovieItem(rows[focus.row].items[focus.column])
            return
        default: break
        }
        movies = browser
    }

    func activateMovieItem(_ item: MovieItem) {
        switch item {
        case .folders:
            movies?.folderRow = 0
        case .movie(let path):
            guard let movie = MovieLibrary.shared.movie(path) else { return }
            if movie.inProgress {
                movies?.resuming = path
                movies?.resumeRow = 0
            } else {
                playMovie(movie, from: 0)
            }
        }
    }

    // MARK: Folders

    private func handleFolders(_ command: RemoteCommand) {
        guard let row = movies?.folderRow else { return }
        let count = MovieLibrary.shared.suggestedFolders.count + 2
        switch command {
        case .back: movies?.folderRow = nil
        case .move(.up): movies?.folderRow = max(0, row - 1)
        case .move(.down): movies?.folderRow = min(count - 1, row + 1)
        case .select: activateFolderRow(row)
        default: break
        }
    }

    func activateFolderRow(_ row: Int) {
        movies?.folderRow = row
        let suggested = MovieLibrary.shared.suggestedFolders
        if suggested.indices.contains(row) {
            // An offline share reconnects; anything else switches on or off.
            let shares = NetworkShares.shared
            if let share = shares.share(for: suggested[row]), shares.status[share.id] != .connected {
                shares.connect(share, addToMovies: false)
            } else {
                MovieLibrary.shared.toggle(suggested[row])
            }
        } else if row == suggested.count {
            movies?.shareForm = ShareForm()
        } else {
            chooseMovieFolder()
        }
    }

    // MARK: Network shares

    private func handleShareForm(_ command: RemoteCommand) {
        guard var form = movies?.shareForm else { return }
        // While connecting, only Back does anything: it closes the form and the share keeps trying.
        if form.connecting { if case .back = command { movies?.shareForm = nil }; return }
        form.message = nil
        form.failed = false
        switch command {
        case .back:
            movies?.shareForm = nil
            return
        case .move(.up): form.row = max(0, form.row - 1)
        case .move(.down): form.row = min(3, form.row + 1)
        case .select:
            if form.row == 3 { movies?.shareForm = form; submitShareForm(); return }
            form.row += 1
        case .text(let text):
            let typed = text.replacingOccurrences(of: "\n", with: "")
            switch form.row {
            case 1: form.user += typed
            case 2: form.password += typed
            default: form.row = 0; form.address += typed
            }
            if text.hasSuffix("\n") { movies?.shareForm = form; handleShareForm(.select); return }
        case .deleteBackward:
            switch form.row {
            case 1: if !form.user.isEmpty { form.user.removeLast() }
            case 2: if !form.password.isEmpty { form.password.removeLast() }
            default: if !form.address.isEmpty { form.address.removeLast() }
            }
        default: break
        }
        movies?.shareForm = form
    }

    /// Adds the share and waits for it to connect: closes on success, or shows why it didn't.
    private func submitShareForm() {
        guard var form = movies?.shareForm else { return }
        let shares = NetworkShares.shared
        guard let share = shares.add(address: form.address, user: form.user, password: form.password) else {
            form.message = form.address.isEmpty ? "Type the shared folder's address first." : "Use an address like nas.local/Movies."
            form.failed = true
            movies?.shareForm = form
            return
        }
        form.connecting = true
        form.message = "Connecting to \(share.host)…"
        movies?.shareForm = form
        Task { @MainActor [weak self] in
            // macOS gives up on an unreachable server after about a minute.
            for _ in 0..<150 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.movies?.shareForm?.connecting == true else { return }
                switch shares.status[share.id] {
                case .connected:
                    self.movies?.shareForm = nil
                    self.showToast("Connected to \(share.name). Its movies are on the way.")
                    return
                case .offline(let reason):
                    self.movies?.shareForm?.connecting = false
                    self.movies?.shareForm?.message = reason
                    self.movies?.shareForm?.failed = true
                    return
                default: continue
                }
            }
        }
    }

    /// The Mac's own folder picker, for anywhere else.
    private func chooseMovieFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders with movies for Mac TV"
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { panel.urls.forEach(MovieLibrary.shared.add) }
        }
    }
}

// MARK: Views

private enum PosterLayout {
    static let size = CGSize(width: 200, height: 300)
    static let spacing: CGFloat = 40
    static let left: CGFloat = 140
    static let rowsTop: CGFloat = 450
    static let rowStride: CGFloat = 432
}

struct MoviesScreen: View {
    @ObservedObject var tv: TVController
    @ObservedObject private var library = MovieLibrary.shared
    @Environment(\.canvasSize) private var canvas
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = tv.movieRows
        let focus = tv.movieFocus
        let item = rows[focus.row].items[focus.column]
        let movie: Movie? = if case .movie(let path) = item { library.movie(path) } else { nil }
        let browser = tv.movies ?? MoviesBrowser()

        ZStack(alignment: .topLeading) {
            MovieBackdrop(image: movie.flatMap { library.posters[$0.path] })
                .id(movie?.path ?? "none")
                .transition(.opacity)

            header(item: item, movie: movie)
                .padding(.leading, PosterLayout.left)
                .frame(height: PosterLayout.rowsTop - 40, alignment: .bottomLeading)

            ClockPill()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 96)
                .padding(.top, 56)

            VStack(alignment: .leading, spacing: 56) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    // Room for a focused poster to grow without covering its row's name.
                    VStack(alignment: .leading, spacing: 42) {
                        Text(row.title ?? " ")
                            .font(.tv(.body, emphasized: true))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(height: 34)
                        HStack(spacing: PosterLayout.spacing) {
                            ForEach(Array(row.items.enumerated()), id: \.element) { column, item in
                                PosterTile(item: item, progress: row.progress,
                                           focused: focus.row == rowIndex && focus.column == column)
                                    .onTapGesture {
                                        tv.movies?.row = rowIndex
                                        tv.movies?.column = column
                                        tv.activateMovieItem(item)
                                    }
                            }
                        }
                    }
                    .opacity(rowIndex < focus.row ? 0 : 1)
                }
            }
            .offset(x: PosterLayout.left, y: PosterLayout.rowsTop - CGFloat(focus.row) * PosterLayout.rowStride)

            if let row = browser.folderRow {
                FoldersSheet(tv: tv, focusedRow: row)
                    .transition(Motion.sheet(reduceMotion: reduceMotion))
            }
            if let form = browser.shareForm {
                ShareFormSheet(tv: tv, form: form)
                    .transition(Motion.sheet(reduceMotion: reduceMotion))
            }
            if let path = browser.resuming, let resuming = library.movie(path) {
                ResumeSheet(movie: resuming, row: browser.resumeRow) { from in
                    tv.movies?.resuming = nil
                    tv.playMovie(resuming, from: from)
                }
                .transition(Motion.sheet(reduceMotion: reduceMotion))
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
        .foregroundStyle(.white)
        .animation(Motion.navigate, value: focus.row)
        .animation(Motion.appear, value: movie?.path)
        .animation(Motion.appear, value: browser.folderRow != nil)
        .animation(Motion.appear, value: browser.resuming)
    }

    @ViewBuilder
    private func header(item: MovieItem, movie: Movie?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch item {
            case .folders:
                Text(library.movies.isEmpty ? "No movies yet" : "Folders")
                    .font(.tv(.title2, emphasized: true))
                Text(library.scanning ? "Looking for movies…" : foldersLine)
                    .font(.tv(.body)).foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: 1100, alignment: .leading)
            case .movie:
                if let movie {
                    Text(movie.displayTitle)
                        .font(.tv(.title2, emphasized: true))
                        .lineLimit(2)
                        .frame(maxWidth: 1300, alignment: .leading)
                    Text(details(of: movie))
                        .font(.tv(.body)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 12)
    }

    private var foldersLine: String {
        let names = library.folders.map { FileManager.default.displayName(atPath: $0.path) }
        let place = names.isEmpty ? "no folders" : ListFormatter.localizedString(byJoining: names)
        return library.movies.isEmpty
            ? "Mac TV shows the video files in \(place). Put movies there, or choose more folders."
            : "Looking in \(place). Choose more folders, or drives."
    }

    private func details(of movie: Movie) -> String {
        var parts: [String] = []
        if let year = movie.year { parts.append(String(year)) }
        if let duration = movie.duration { parts.append(Self.length(duration)) }
        if movie.inProgress, let position = movie.position, let duration = movie.duration {
            parts.append("\(Self.length(duration - position)) left")
        }
        parts.append(movie.url.pathExtension.uppercased())
        return parts.joined(separator: "  ·  ")
    }

    static func length(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(max(minutes, 1)) min"
    }
}

/// The focused movie's poster, blurred across the screen behind everything, like Apple TV's
/// app pages.
struct MovieBackdrop: View {
    let image: NSImage?
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        ZStack {
            Color(hex: "#0B0C10")
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: canvas.width, height: canvas.height)
                    .blur(radius: 90)
                    .saturation(1.2)
                    .opacity(0.75)
                    .clipped()
            }
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: canvas.width, height: canvas.height)
    }
}

struct PosterTile: View {
    let item: MovieItem
    let progress: Bool
    let focused: Bool
    @ObservedObject private var library = MovieLibrary.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        artwork
            .frame(width: PosterLayout.size.width, height: PosterLayout.size.height)
            .clipShape(shape)
            .overlay {
                RadialGradient(colors: [.white.opacity(0.28), .white.opacity(0)], center: UnitPoint(x: 0.5, y: 0.02),
                               startRadius: 0, endRadius: PosterLayout.size.height * 0.8)
                    .blendMode(.plusLighter)
                    .clipShape(shape)
                    .opacity(focused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(focused ? 0.55 : 0.12), .white.opacity(focused ? 0.08 : 0.03)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: focused ? 1.5 : 1)
            }
            .overlay(alignment: .bottom) { progressBar }
            .scaleEffect(focused ? (reduceMotion ? 1.05 : 1.12) : 1)
            .offset(y: focused && !reduceMotion ? -8 : 0)
            .shadow(color: .black.opacity(focused ? 0.6 : 0.25), radius: focused ? 28 : 10, y: focused ? 22 : 6)
            .zIndex(focused ? 1 : 0)
            .animation(Motion.focus, value: focused)
    }

    @ViewBuilder private var artwork: some View {
        switch item {
        case .folders:
            ZStack {
                Color.white.opacity(0.08)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                Image(systemName: "folder.badge.plus").font(.system(size: 56, weight: .medium)).symbolRenderingMode(.hierarchical)
            }
        case .movie(let path):
            if let image = library.posters[path] {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                // Until the poster arrives: the film icon on graphite.
                ZStack {
                    LinearGradient(colors: [Color(hex: "#3A3A3C"), Color(hex: "#1C1C1E")], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "film").font(.system(size: 54, weight: .light)).opacity(0.5)
                }
            }
        }
    }

    @ViewBuilder private var progressBar: some View {
        if progress, case .movie(let path) = item, let movie = library.movie(path),
           let position = movie.position, let duration = movie.duration, duration > 0 {
            GeometryReader { geo in
                Capsule().fill(.white.opacity(0.3))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white).frame(width: geo.size.width * min(1, position / duration))
                    }
            }
            .frame(height: 6)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .shadow(color: .black.opacity(0.5), radius: 4)
        }
    }
}

/// Which folders Mac TV looks in: switches for the usual places and drives, and the Mac's own
/// picker for anywhere else.
struct FoldersSheet: View {
    @ObservedObject var tv: TVController
    let focusedRow: Int
    @ObservedObject private var library = MovieLibrary.shared
    @ObservedObject private var shares = NetworkShares.shared
    @Environment(\.canvasSize) private var canvas
    @Namespace private var focusSpace

    var body: some View {
        let folders = library.suggestedFolders
        VStack(alignment: .leading, spacing: 10) {
            Text("Folders").font(.tv(.title3, emphasized: true))
            Text("Mac TV shows the movies in the folders you turn on, including folders inside them.")
                .font(.tv(.caption2)).foregroundStyle(.white.opacity(0.65))
                .padding(.bottom, 14)
            ForEach(Array(folders.enumerated()), id: \.element) { index, folder in
                if let share = shares.share(for: folder) {
                    let status = shares.status[share.id] ?? .connecting
                    row(index, systemImage: "server.rack", title: share.name) {
                        if status == .connected {
                            SettingSwitch(on: library.isWatched(folder))
                        } else {
                            Text(status.text).font(.tv(.caption1)).opacity(0.6)
                        }
                    }
                } else {
                    row(index, systemImage: folder.path.hasPrefix("/Volumes/") ? "externaldrive.fill" : "folder.fill",
                        title: FileManager.default.displayName(atPath: folder.path)) {
                        SettingSwitch(on: library.isWatched(folder))
                    }
                }
            }
            row(folders.count, systemImage: "plus", title: "Add Network Share…") {
                Image(systemName: "chevron.right").font(.system(size: 22, weight: .semibold)).opacity(0.6)
            }
            row(folders.count + 1, systemImage: "folder.badge.plus", title: "Choose Another Folder…") {
                Image(systemName: "chevron.right").font(.system(size: 22, weight: .semibold)).opacity(0.6)
            }
        }
        .padding(56)
        .frame(width: 980, alignment: .leading)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .frame(width: canvas.width, height: canvas.height)
        .background(Color.black.opacity(0.35))
        .animation(Motion.focus, value: focusedRow)
    }

    private func row<Trailing: View>(_ index: Int, systemImage: String, title: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        let focused = index == focusedRow
        return HStack(spacing: 18) {
            Image(systemName: systemImage).font(.system(size: 24)).frame(width: 34)
            Text(title).font(.tv(.body)).lineLimit(1)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
        .foregroundStyle(focused ? .black : .white)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            if focused {
                shape.fill(.white).matchedGeometryEffect(id: "focus", in: focusSpace)
            } else {
                shape.fill(.white.opacity(0.08))
            }
        }
        .scaleEffect(focused ? 1.02 : 1)
        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 14, y: 8)
        .contentShape(Rectangle())
        .onTapGesture { tv.activateFolderRow(index) }
    }
}

/// Apple TV's choice for a movie you've started: carry on, or from the beginning.
struct ResumeSheet: View {
    let movie: Movie
    let row: Int
    let choose: (Double) -> Void
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let position = movie.position ?? 0
        VStack(spacing: 18) {
            Text(movie.displayTitle).font(.tv(.callout, emphasized: true)).lineLimit(2).multilineTextAlignment(.center)
                .padding(.bottom, 10)
            button("Resume from \(MoviePlayerView.clock(position))", systemImage: "play.fill", focused: row == 0) {
                choose(max(0, position - 5))
            }
            button("Start from the Beginning", systemImage: "arrow.counterclockwise", focused: row == 1) { choose(0) }
        }
        .padding(48)
        .frame(width: 720)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 40, style: .continuous))
        .tvPanel(in: RoundedRectangle(cornerRadius: 40, style: .continuous))
        .frame(width: canvas.width, height: canvas.height)
        .background(Color.black.opacity(0.35))
    }

    private func button(_ title: String, systemImage: String, focused: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.system(size: 26, weight: .semibold))
        .frame(maxWidth: .infinity)
        .frame(height: 70)
        .foregroundStyle(focused ? .black : .white)
        .background(focused ? .white : .white.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .scaleEffect(focused ? 1.03 : 1)
        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 14, y: 8)
        .animation(Motion.focus, value: focused)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

// MARK: Player

/// A movie on the TV: the picture, subtitles, and Apple TV's controls in Liquid Glass: back at
/// the top, skip and play/pause in the middle, and the title, subtitle and audio buttons and the
/// progress bar at the bottom. The remote drives them (left and right skip, select plays or
/// pauses, down opens subtitles and audio) and so does the mouse.
struct MoviePlayerView: View {
    @ObservedObject var player: MoviePlayer

    var body: some View {
        ZStack {
            LayerHost(layer: player.engine.layer).ignoresSafeArea()
                .onTapGesture { player.togglePlayback() }

            TVCanvas {
                ZStack(alignment: .bottom) {
                    if let text = player.subtitleText {
                        Text(text)
                            .font(.tv(.title3))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.9), radius: 3)
                            .shadow(color: .black.opacity(0.6), radius: 10)
                            .padding(.horizontal, 200)
                            .padding(.bottom, player.controlsVisible ? 300 : 80)
                            .animation(Motion.appear, value: player.controlsVisible)
                            .allowsHitTesting(false)
                    }
                    if player.controlsVisible {
                        controls.transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .foregroundStyle(.white)
            }
            .ignoresSafeArea()
        }
        .background(Color.black)
        .onContinuousHover { phase in
            if case .active(let point) = phase { player.pointerMoved(to: point) }
        }
    }

    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom).frame(height: 240)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom).frame(height: 480)
            }
            .allowsHitTesting(false)

            PlayerButton(symbol: "chevron.backward", size: 72, action: { player.onClose?() })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 96)
                .padding(.top, 64)

            GlassGroup(spacing: 0) {
                HStack(spacing: 56) {
                    TransportButton(symbol: "gobackward.10", size: 100, pressed: player.pressed == "back") { player.skip(-10) }
                    TransportButton(symbol: player.playing ? "pause.fill" : "play.fill", size: 136,
                                     pressed: player.pressed == "playpause") { player.togglePlayback() }
                    TransportButton(symbol: "goforward.10", size: 100, pressed: player.pressed == "forward") { player.skip(10) }
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                if let menu = player.menu {
                    menuView(menu).frame(maxWidth: .infinity, alignment: .trailing)
                }
                HStack(alignment: .bottom, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(player.movie.displayTitle)
                            .font(.tv(.headline, emphasized: true))
                            .lineLimit(1)
                        if !details.isEmpty {
                            Text(details).font(.tv(.caption2)).opacity(0.7)
                        }
                    }
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    Spacer(minLength: 0)
                    GlassGroup {
                        HStack(spacing: 18) {
                            if !player.subtitleOptions.isEmpty {
                                PlayerButton(symbol: player.selectedSubtitle == nil ? "captions.bubble" : "captions.bubble.fill",
                                             size: 68, lit: player.menuShowsSubtitles) { player.toggleMenu(subtitles: true) }
                            }
                            if player.audioOptions.count > 1 {
                                PlayerButton(symbol: "speaker.wave.2.bubble", size: 68,
                                             lit: player.menu != nil && !player.menuShowsSubtitles) { player.toggleMenu(subtitles: false) }
                            }
                        }
                    }
                }
                progress
                HStack {
                    Text(Self.clock(player.time))
                    Spacer()
                    Text("-" + Self.clock(max(0, player.duration - player.time)))
                }
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
                .shadow(color: .black.opacity(0.5), radius: 6)
            }
            .padding(.horizontal, 110)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// The year and the language you're hearing.
    private var details: String {
        var parts: [String] = []
        if let year = player.movie.year { parts.append(String(year)) }
        if let audio = player.selectedAudio, player.audioOptions.indices.contains(audio) {
            let option = player.audioOptions[audio]
            if MediaOption.languageCode(option.language) != nil { parts.append(option.title) }
        }
        return parts.joined(separator: "  ·  ")
    }

    /// The progress bar; click anywhere on it to jump there.
    private var progress: some View {
        GeometryReader { geo in
            let fraction = player.duration > 0 ? min(1, player.time / player.duration) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28)).frame(height: 12)
                Capsule().fill(.white).frame(width: max(12, geo.size.width * fraction), height: 12)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { location in player.seek(toFraction: location.x / max(geo.size.width, 1)) }
        }
        .frame(height: 36)
        .shadow(color: .black.opacity(0.4), radius: 6)
    }

    private func menuView(_ menu: MoviePlayer.Menu) -> some View {
        let columns = player.menuColumns
        let titles = columns.count == 2 ? ["Audio", "Subtitles"] : ["Subtitles"]
        return HStack(alignment: .top, spacing: 40) {
            ForEach(Array(columns.enumerated()), id: \.offset) { column, options in
                VStack(alignment: .leading, spacing: 8) {
                    Text(titles[column]).font(.tv(.caption2, emphasized: true)).textCase(.uppercase).tracking(1).opacity(0.6)
                        .padding(.leading, 16)
                    ForEach(Array(options.enumerated()), id: \.offset) { row, title in
                        let focused = menu.column == column && menu.row == row
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark").opacity(player.selectedRow(in: column) == row ? 1 : 0)
                            Text(title).lineLimit(1)
                        }
                        .font(.system(size: 24, weight: .semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .frame(minWidth: 300, alignment: .leading)
                        .foregroundStyle(focused ? .black : .white)
                        .background(focused ? .white : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { player.choose(column: column, row: row) }
                    }
                }
            }
        }
        .padding(24)
        .tvGlass(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .animation(Motion.focus, value: menu)
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A small round glass control at the player's edges (back, subtitles, audio). `lit` shows it
/// white while its menu is open.
struct PlayerButton: View {
    let symbol: String
    let size: CGFloat
    var lit = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if lit { Circle().fill(.white) }
                Image(systemName: symbol)
                    .font(.system(size: size * 0.38, weight: .semibold))
            }
            .frame(width: size, height: size)
            .foregroundStyle(lit ? .black : .white)
            .tvGlass(in: Circle())
            .contentShape(Circle())
            .animation(Motion.press, value: lit)
        }
        .buttonStyle(PressStyle(pressed: false))
    }
}

/// The middle controls: skip and play/pause in glass circles. A press, from the remote
/// (`pressed`) or a click, dips the whole circle slightly and it settles back.
struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    var pressed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .contentTransition(.symbolEffect(.replace.downUp))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .tvGlass(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(pressed: pressed))
    }
}

/// A press: the control dips a little and settles back, with no bounce.
private struct PressStyle: ButtonStyle {
    let pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(pressed || configuration.isPressed ? 0.94 : 1)
            .animation(Motion.press, value: pressed || configuration.isPressed)
    }
}

/// Shows a Core Animation layer (the video) filling the view.
struct LayerHost: NSViewRepresentable {
    let layer: CALayer

    final class Host: NSView {
        var hosted: CALayer?
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor.black
        view.layer?.addSublayer(layer)
        view.hosted = layer
        return view
    }

    func updateNSView(_ nsView: Host, context: Context) {}
}

/// Add Network Share on the TV: the address, an optional user name and password, then Connect.
struct ShareFormSheet: View {
    @ObservedObject var tv: TVController
    let form: ShareForm
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Add Network Share").font(.tv(.title3, emphasized: true))
            AdderField(label: "Shared folder", text: form.address, placeholder: "e.g. nas.local/Movies", focused: form.row == 0) { set(0) }
            AdderField(label: "User name", text: form.user, placeholder: "Leave empty for guest", focused: form.row == 1) { set(1) }
            AdderField(label: "Password", text: String(repeating: "•", count: form.password.count), placeholder: "Password",
                       focused: form.row == 2) { set(2) }
            ShelfButton(title: form.connecting ? "Connecting…" : "Connect", systemImage: "server.rack", focused: form.row == 3, glass: false) {
                set(3)
                tv.handle(.select)
            }
            Text(form.message ?? "Type with the keyboard or the remote's typing box. The password stays in this Mac's Keychain.")
                .font(.tv(.caption2, emphasized: form.message != nil))
                .foregroundStyle(form.failed ? Color(hex: "#FF8A80") : .white.opacity(form.message == nil ? 0.55 : 0.9))
                .lineLimit(2)
                .frame(minHeight: 64, alignment: .topLeading)
        }
        .padding(56)
        .frame(width: 1000, alignment: .leading)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .background(Color.black.opacity(0.35))
        .animation(Motion.focus, value: form)
    }

    private func set(_ row: Int) {
        guard tv.movies?.shareForm?.connecting == false else { return }
        tv.movies?.shareForm?.row = row
    }
}
