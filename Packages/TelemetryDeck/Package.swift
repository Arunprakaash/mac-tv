// swift-tools-version: 5.9
// TelemetryDeck's Swift SDK 2.14.2 (https://github.com/TelemetryDeck/SwiftSDK, MIT, see LICENSE),
// vendored unchanged except for this manifest: it targets macOS 14 like Mac TV, so the universal
// build doesn't need Swift's back-deployment libraries, which the command-line tools ship for arm64 only.
import PackageDescription

let package = Package(
    name: "TelemetryDeck",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TelemetryDeck", targets: ["TelemetryDeck"])],
    targets: [
        .target(name: "TelemetryDeck", resources: [.copy("PrivacyInfo.xcprivacy")],
                swiftSettings: [.enableExperimentalFeature("StrictConcurrency")])
    ]
)
