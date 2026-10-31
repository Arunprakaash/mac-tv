import SwiftUI

/// Each streaming app's popular shows for the Top Shelf, like Apple TV's. The list is bundled
/// (TopShelf.json, from TVmaze; scripts/update-top-shelf.py refreshes it) and the images are
/// downloaded once into ~/Library/Application Support/Mac TV/Top Shelf. Nothing here comes from
/// what you watch.
@MainActor
final class TopShelfFeed: ObservableObject {
    struct Show: Decodable, Hashable, Identifiable {
        let id: Int
        let name: String
        let image: URL
        /// The show's own title logo, when Wikidata has one.
        let logo: URL?
    }

    /// A title logo, and whether to draw it white (a dark single-colour logo would vanish on dark art).
    struct Logo {
        let image: NSImage
        let asWhite: Bool
    }

    private struct File: Decodable {
        let services: [String: [Show]]
    }

    static let shared = TopShelfFeed()

    /// Shows whose image is ready, by app id.
    @Published private(set) var ready: [String: [Show]] = [:]
    /// Moves on every few seconds: which show each app's Top Shelf is on.
    @Published private(set) var turn = 0
    /// When the current show came up, for its slow drift.
    private(set) var turnStarted = Date()
    private var clock: Timer?
    private(set) var images: [Int: NSImage] = [:]
    /// Title logos by show id; shows without one just get the artwork.
    @Published private(set) var logos: [Int: Logo] = [:]
    private let lists: [String: [Show]]
    private let folder = AppFolder.url.appendingPathComponent("Top Shelf", isDirectory: true)
    private var started = false

    private init() {
        let file = Bundle.main.url(forResource: "TopShelf", withExtension: "json")
        lists = file.flatMap { try? JSONDecoder().decode(File.self, from: Data(contentsOf: $0)) }?.services ?? [:]
    }

    /// An app's shows that are ready to show. When at least three have a title logo, only those,
    /// so the Top Shelf always carries the show's real title.
    func shows(for serviceID: String) -> [Show] {
        let all = ready[serviceID] ?? []
        let titled = all.filter { $0.logo != nil }
        return titled.count >= 3 ? titled : all
    }

    /// Loads cached images, and downloads the rest in the background.
    func start() {
        guard !started else { return }
        started = true
        clock = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.turnStarted = Date()
                withAnimation(.easeInOut(duration: 1.4)) { self.turn += 1 }
            }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (serviceID, shows) in lists {
            for show in shows {
                loadLogo(for: show)
                let file = folder.appendingPathComponent("\(show.id).jpg")
                if let image = NSImage(contentsOf: file) {
                    add(show, image, to: serviceID)
                    continue
                }
                Task {
                    guard let (data, response) = try? await URLSession.shared.data(from: show.image),
                          (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { return }
                    try? data.write(to: file, options: .atomic)
                    add(show, image, to: serviceID)
                }
            }
        }
    }

    private func loadLogo(for show: Show) {
        guard let url = show.logo else { return }
        let file = folder.appendingPathComponent("\(show.id)-logo.png")
        if let data = try? Data(contentsOf: file), let logo = Self.logo(from: data) {
            logos[show.id] = logo
            return
        }
        Task {
            var request = URLRequest(url: url)
            // Wikimedia asks apps to say who they are.
            request.setValue("MacTV (https://github.com/Arunprakaash/mac-tv)", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, let logo = Self.logo(from: data) else { return }
            try? data.write(to: file, options: .atomic)
            logos[show.id] = logo
        }
    }

    /// Reads a logo and decides whether it's a dark single-colour mark that needs drawing in white.
    private static func logo(from data: Data) -> Logo? {
        guard let image = NSImage(data: data), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = 64, height = max(1, 64 * cg.height / max(cg.width, 1))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var light = 0.0, colour = 0.0, count = 0.0
        // A logo on a solid background isn't a title mark; the art alone is better.
        let opaque = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 250 }.count
        guard Double(opaque) / Double(width * height) < 0.85 else { return nil }
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 128 {
            let a = Double(pixels[i + 3]) / 255
            let r = Double(pixels[i]) / 255 / a, g = Double(pixels[i + 1]) / 255 / a, b = Double(pixels[i + 2]) / 255 / a
            light += 0.299 * r + 0.587 * g + 0.114 * b
            colour += max(r, g, b) - min(r, g, b)
            count += 1
        }
        guard count > 0 else { return nil }
        return Logo(image: image, asWhite: light / count < 0.45 && colour / count < 0.2)
    }

    private func add(_ show: Show, _ image: NSImage, to serviceID: String) {
        images[show.id] = image
        // Keep the list's order (most popular first), whatever order the images arrive in.
        let order = lists[serviceID] ?? []
        let have = Set((ready[serviceID] ?? []).map(\.id)).union([show.id])
        ready[serviceID] = order.filter { have.contains($0.id) }
    }
}

/// A show's artwork, full bleed, drifting slowly the way Apple TV's Top Shelf does.
struct ShowBackdrop: View {
    let image: NSImage
    let since: Date
    @Environment(\.canvasSize) private var canvas
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            picture(progress: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                picture(progress: min(1, context.date.timeIntervalSince(since) / 10))
            }
        }
    }

    private func picture(progress: Double) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: canvas.width, height: canvas.height)
            .scaleEffect(1 + 0.06 * progress)
            .offset(x: -18 * progress)
            .clipped()
    }
}
