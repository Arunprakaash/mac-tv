import Foundation

/// The app-wide services TVController and its features use, handed in rather than reached for, so
/// a test can give Mac TV its own. The app uses the shared ones.
@MainActor
struct AppServices {
    var preferences: Preferences = .shared
    var movieLibrary: MovieLibrary = .shared
    var jellyfin: JellyfinServers = .shared
    var networkShares: NetworkShares = .shared
    var updater: Updater = .shared
    var topShelf: TopShelfFeed = .shared
    var feedback: Feedback = .shared
}
