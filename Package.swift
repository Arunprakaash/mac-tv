// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacTV",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Opt-in, anonymous usage analytics (off until the user agrees). https://telemetrydeck.com
        // Vendored in Packages/TelemetryDeck: see its Package.swift for why.
        .package(path: "Packages/TelemetryDeck"),
    ],
    targets: [
        .executableTarget(
            name: "MacTV",
            dependencies: [.product(name: "TelemetryDeck", package: "TelemetryDeck")],
            path: "Sources/MacTV",
            // The phone remote's web page (Features/Remote/RemotePage.swift serves it).
            resources: [.copy("Features/Remote/Page")]
        ),
        .testTarget(name: "MacTVTests", dependencies: ["MacTV"], path: "Tests/MacTVTests")
    ]
)
