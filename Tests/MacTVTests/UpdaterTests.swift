import Testing
@testable import MacTV

@Suite @MainActor
struct UpdaterTests {
    @Test
    func comparesDottedVersionsNumerically() {
        #expect(Updater.isNewer("0.12", than: "0.11.1"))
        #expect(Updater.isNewer("0.10", than: "0.9"))
        #expect(Updater.isNewer("1.0", than: "0.99"))
        #expect(Updater.isNewer("0.12.1", than: "0.12"))
        #expect(!Updater.isNewer("0.12", than: "0.12"))
        #expect(!Updater.isNewer("0.12", than: "0.12.0"))
        #expect(!Updater.isNewer("0.11.1", than: "0.12"))
    }
}
