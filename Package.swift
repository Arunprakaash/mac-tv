// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacTV",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MacTV", path: "Sources/MacTV")
    ]
)
