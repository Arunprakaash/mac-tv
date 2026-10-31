import Foundation
import Testing
@testable import MacTV

@Suite @MainActor
struct MovieFoldersTests {
    private let movies = URL(fileURLWithPath: "/test-home/Movies", isDirectory: true)
    private let downloads = URL(fileURLWithPath: "/test-home/Downloads", isDirectory: true)
    private let custom = URL(fileURLWithPath: "/Volumes/Films", isDirectory: true)

    @Test
    func freshPreferencesIncludeMoviesAndDownloads() throws {
        let name = "MovieFoldersTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = MovieFolderPreferences(defaults: defaults, movies: movies, downloads: downloads)
        #expect(preferences.folders.map(\.path) == [movies.path, downloads.path])
    }

    @Test
    func migrationPreservesCustomFoldersAndDoesNotReenableDownloads() throws {
        let name = "MovieFoldersTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set([custom.path], forKey: "movieFolders")
        let preferences = MovieFolderPreferences(defaults: defaults, movies: movies, downloads: downloads)
        #expect(preferences.folders.map(\.path) == [custom.path, downloads.path])
        preferences.folders = [custom]
        let reopened = MovieFolderPreferences(defaults: defaults, movies: movies, downloads: downloads)
        #expect(reopened.folders.map(\.path) == [custom.path])
    }

    @Test
    func migrationDoesNotDuplicateEquivalentDownloadsPath() throws {
        let name = "MovieFoldersTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set([movies.path, "/test-home/./Downloads/"], forKey: "movieFolders")
        let preferences = MovieFolderPreferences(defaults: defaults, movies: movies, downloads: downloads)
        #expect(preferences.folders.map(\.path) == [movies.path, downloads.path])
    }
}
