import Foundation
import Testing
@testable import MacTV

@Suite
struct JellyfinTests {
    private let server = JellyfinServers.Server(id: "srv1", name: "Family Movies", address: "http://192.168.1.5:8096",
                                                userID: "u1", user: "amma", on: true)

    @Test
    func readsServerAddresses() {
        #expect(JellyfinServers.address("192.168.1.5")?.absoluteString == "http://192.168.1.5:8096")
        #expect(JellyfinServers.address("100.92.2.111:8096")?.absoluteString == "http://100.92.2.111:8096")
        #expect(JellyfinServers.address(" nas.local:8920/ ")?.absoluteString == "http://nas.local:8920")
        #expect(JellyfinServers.address("http://host:8096/web/#/home")?.absoluteString == "http://host:8096")
        #expect(JellyfinServers.address("https://tv.example.com/jellyfin/")?.absoluteString == "https://tv.example.com/jellyfin")
        #expect(JellyfinServers.address("HTTPS://tv.example.com")?.absoluteString == "https://tv.example.com")
        #expect(JellyfinServers.address("") == nil)
        #expect(JellyfinServers.address("my server") == nil)
        #expect(JellyfinServers.address("smb://nas.local/Movies") == nil)
    }

    @Test
    func knowsTailscaleAddresses() {
        #expect(JellyfinServers.isTailscaleAddress("100.92.2.111"))
        #expect(JellyfinServers.isTailscaleAddress("100.64.0.1"))
        #expect(!JellyfinServers.isTailscaleAddress("100.128.0.1"))
        #expect(!JellyfinServers.isTailscaleAddress("192.168.1.5"))
        #expect(!JellyfinServers.isTailscaleAddress("nas.local"))
    }

    @Test
    func leavesOtherAddressesAlone() async {
        let url = URL(string: "http://192.168.1.5:8096")!
        #expect(await JellyfinServers.tailscaleName(for: url) == url)
    }

    @Test
    func pathsCarryServerAndItem() {
        #expect(JellyfinServers.ids(in: "jellyfin://srv1/abc")?.server == "srv1")
        #expect(JellyfinServers.ids(in: "jellyfin://srv1/abc")?.item == "abc")
        #expect(JellyfinServers.ids(in: "/Users/me/Movies/abc.mp4") == nil)
        #expect(Movie(path: "jellyfin://srv1/abc", title: "A", added: .now, size: 0).isRemote)
        #expect(!Movie(path: "/Users/me/Movies/abc.mp4", title: "A", added: .now, size: 0).isRemote)
    }

    @Test
    func readsMovies() throws {
        let item: [String: Any] = [
            "Id": "m1", "Name": "Dorothy", "Type": "Movie", "ProductionYear": 2026,
            "DateCreated": "2026-10-30T12:34:56.1234567Z", "RunTimeTicks": 72_000_000_000,
            "ImageTags": ["Primary": "tag"],
            "UserData": ["PlaybackPositionTicks": 6_000_000_000, "LastPlayedDate": "2026-10-31T08:00:00.0000000Z"],
        ]
        let movie = try #require(JellyfinServers.movie(from: item, server: server))
        #expect(movie.path == "jellyfin://srv1/m1")
        #expect(movie.title == "Dorothy")
        #expect(movie.year == 2026)
        #expect(movie.episode == nil)
        #expect(movie.server == "Family Movies")
        #expect(movie.duration == 7200)
        #expect(movie.position == 600)
        #expect(movie.inProgress)
        #expect(movie.artwork == "m1")
        #expect(!movie.posterChecked)
        #expect(movie.added == ISO8601DateFormatter().date(from: "2026-10-30T12:34:56Z"))
        #expect(movie.lastWatched == ISO8601DateFormatter().date(from: "2026-10-31T08:00:00Z"))
    }

    @Test
    func readsEpisodesWithTheirShowsPoster() throws {
        let item: [String: Any] = [
            "Id": "e1", "Name": "Pilot", "Type": "Episode", "SeriesName": "The Show", "SeriesId": "s1",
            "SeriesPrimaryImageTag": "tag", "ParentIndexNumber": 2, "IndexNumber": 5,
        ]
        let movie = try #require(JellyfinServers.movie(from: item, server: server))
        #expect(movie.title == "The Show")
        #expect(movie.episode == "S2 E5")
        #expect(movie.artwork == "s1")
        #expect(movie.position == nil)
    }

    @Test
    func dropsTheYearFromFolderNamedTitles() throws {
        let movie = try #require(JellyfinServers.movie(from: ["Id": "m3", "Name": "Test Pattern (2026)", "ProductionYear": 2026],
                                                       server: server))
        #expect(movie.title == "Test Pattern")
        #expect(movie.year == 2026)
    }

    @Test
    func movieWithoutPictureIsNotLookedUp() throws {
        let movie = try #require(JellyfinServers.movie(from: ["Id": "m2", "Name": "Home Video"], server: server))
        #expect(movie.artwork == nil)
        #expect(movie.posterChecked)
    }

    @Test
    func keepsTheNewerPlace() {
        var served = Movie(path: "jellyfin://srv1/m1", title: "Dorothy", added: .now, size: 0)
        served.position = 600
        served.lastWatched = Date(timeIntervalSince1970: 1000)
        var known = served
        known.poster = "poster.jpg"
        known.posterChecked = true

        // Watched further here since the server last heard: keep this Mac's place.
        known.position = 900
        known.lastWatched = Date(timeIntervalSince1970: 2000)
        var merged = MovieLibrary.update(known, from: served)
        #expect(merged.position == 900)
        #expect(merged.poster == "poster.jpg")

        // Finished in another Jellyfin app since: the server's word wins.
        served.position = nil
        served.lastWatched = Date(timeIntervalSince1970: 3000)
        merged = MovieLibrary.update(known, from: served)
        #expect(merged.position == nil)
        #expect(merged.posterChecked)
    }

    @Test
    func sameFilmMatchesAcrossSources() {
        let name = MovieName("Test Pattern MP4 (2026)")
        let file = Movie(path: "/Users/me/Movies/a.mp4", title: name.title, year: name.year, added: .now, size: 1)
        let served = Movie(path: "jellyfin://srv1/m1", title: "Test Pattern MP4", year: 2026, added: .now, size: 0)
        #expect(MovieLibrary.matchKey(file) == MovieLibrary.matchKey(served))
        var other = served
        other.year = 2025
        #expect(MovieLibrary.matchKey(file) != MovieLibrary.matchKey(other))
    }

    @Test
    func explainsFailures() {
        #expect(JellyfinServers.message(for: JellyfinServers.Failure.http(401), signingIn: true) == "Wrong user name or password")
        #expect(JellyfinServers.message(for: JellyfinServers.Failure.http(401), signingIn: false) == "Sign in again")
        let url = URL(string: "http://100.92.2.111:8096/System/Info/Public")!
        #expect(JellyfinServers.message(for: URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: url]),
                                        signingIn: true) == "Nothing is answering at 100.92.2.111:8096")
        #expect(JellyfinServers.message(for: URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url]),
                                        signingIn: true) == "No answer from 100.92.2.111:8096")
        #expect(JellyfinServers.message(for: URLError(.notConnectedToInternet,
                                                      userInfo: ["_NSURLErrorNWPathKey": "unsatisfied (Local network prohibited)"]),
                                        signingIn: true).contains("Local Network"))
        #expect(JellyfinServers.message(for: URLError(.appTransportSecurityRequiresSecureConnection), signingIn: true)
                .contains("IP address"))
        #expect(JellyfinServers.message(for: JellyfinServers.Failure.notJellyfin, signingIn: true) == "Not a Jellyfin server")
    }
}
