import SwiftUI

struct TopShelf: View {
    @ObservedObject var tv: TVController
    let expanded: Bool
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let service = tv.shelfService
        Group {
            if tv.shelfCount > 0 {
                AppBanner(tv: tv, service: service, expanded: expanded)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .id(service.id)
        .transition(.opacity)
    }
}

/// The focused app's colours across the screen, with its name top-left. Moving up from the
/// dock brings up Open. Nothing about what was watched ever shows here.
struct AppBanner: View {
    @ObservedObject var tv: TVController
    @ObservedObject private var feed: TopShelfFeed
    @ObservedObject private var movieLibrary: MovieLibrary
    @Environment(\.canvasSize) private var canvas
    let service: Service
    let expanded: Bool

    init(tv: TVController, service: Service, expanded: Bool) {
        _tv = ObservedObject(wrappedValue: tv)
        _feed = ObservedObject(wrappedValue: tv.topShelf)
        _movieLibrary = ObservedObject(wrappedValue: tv.movieLibrary)
        self.service = service
        self.expanded = expanded
    }

    /// What the Top Shelf shows now: the Movies app's own movies, or the app's popular shows.
    private var backdrop: (id: String, name: String, image: NSImage, cover: Bool)? {
        if case .movies = service.kind {
            let shelf = movieLibrary.shelf
            if !shelf.isEmpty {
                let pick = shelf[feed.turn % shelf.count]
                // Posters sit on the right like album covers; frames from the film fill the screen.
                return (pick.path, movieLibrary.movies.first(where: { $0.path == pick.path })?.displayTitle ?? "Movies", pick.image, pick.image.size.height > pick.image.size.width)
            }
        }
        guard let show = feed.currentShow(for: service.id) else { return nil }
        return feed.image(for: show.id).map { (String(show.id), show.name, $0, show.square) }
    }

    var body: some View {
        let show = backdrop
        ZStack(alignment: .topLeading) {
            Artwork(accent: service.accent, deep: service.deep)
                .frame(width: canvas.width, height: canvas.height)
                .clipped()
            // Popular shows on this app, cross-fading one to the next, like Apple TV's Top Shelf.
            if let show {
                if show.cover {
                    AlbumBackdrop(image: show.image)
                        .id(show.id)
                        .transition(.opacity)
                } else {
                    // One view for every show: it cross-fades to the next picture itself, in Core Animation.
                    ShowBackdrop(image: show.image, since: feed.turnStarted)
                }
            }
            // Legibility: a soft top-left wash for the name, a bottom wash for the dock or button.
            LinearGradient(stops: [.init(color: .black.opacity(expanded ? 0.8 : (show == nil ? 0.55 : 0.18)), location: 0),
                                   .init(color: .black.opacity(expanded ? 0.4 : 0.15), location: 0.4),
                                   .init(color: .clear, location: 0.65)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.45),
                                   .init(color: .black.opacity(show == nil ? 0.75 : 0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            if show != nil {
                LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .top, endPoint: .center)
            }

            VStack(alignment: .leading, spacing: 12) {
                if show == nil {
                    // The show's artwork alone carries it; nothing is drawn over it. Without art, the app's name.
                    Text(service.name)
                        .font(.tv(.title1, emphasized: true))
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                }
                if expanded {
                    HStack(spacing: 18) {
                        if feed.searchURL(for: service) != nil {
                            ShelfButton(title: "Search in \(service.name)", systemImage: "magnifyingglass", focused: tv.focus == .shelf(0)) {
                                tv.setFocus(.shelf(0)); tv.activateShelf(0)
                            }
                        }
                        let openIndex = feed.searchURL(for: service) == nil ? 0 : 1
                        ShelfButton(title: "Open \(service.name)", systemImage: "arrow.up.right", focused: tv.focus == .shelf(openIndex)) {
                            tv.setFocus(.shelf(openIndex)); tv.activateShelf(openIndex)
                        }
                    }
                    .padding(.top, 20)
                    .tvGlassTransition()
                }
            }
            .frame(width: 1100, alignment: .leading)
            .padding(.leading, 96)
            .frame(maxHeight: .infinity, alignment: expanded ? .bottomLeading : .topLeading)
            .padding(.top, 96)
            .padding(.bottom, 110)
        }
    }
}

/// tvOS buttons: glass at rest, white with dark text when focused.
struct ShelfButton: View {
    let title: String
    var systemImage: String? = nil
    let focused: Bool
    /// Glass over artwork, like the Top Shelf; a plain platter on a frosted sheet, where glass has nothing to refract.
    var glass = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.tv(.callout, emphasized: true))
            .padding(.horizontal, 38)
            .frame(height: 72)
            .foregroundStyle(focused ? .black : .white)
            .background {
                if !glass { Capsule().fill(.white.opacity(0.12)) }
            }
            .focusPlatter(Capsule(), focused: focused, glass: glass)
            .scaleEffect(focused ? 1.08 : 1)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 20, y: 14)
            .animation(Motion.focus, value: focused)
        }
        .buttonStyle(.plain)
    }
}

/// A still in the app's own colours, behind the Top Shelf and its cards. Pictures of what you
/// played aren't shown on the home screen.
struct Artwork: View {
    let accent: String
    let deep: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: deep), Color(hex: "#050608")], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(hex: accent).opacity(0.8), Color(hex: accent).opacity(0.2), .clear],
                           center: UnitPoint(x: 0.74, y: 0.28), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [Color(hex: accent).opacity(0.36), .clear],
                           center: UnitPoint(x: 0.56, y: 0.62), startRadius: 0, endRadius: 420)
        }
    }
}

// MARK: Settings › Remote
