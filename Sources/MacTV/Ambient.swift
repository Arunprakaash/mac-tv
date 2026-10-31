import AppKit
import ImageIO
import QuartzCore
import SwiftUI

// Slow, always-on motion (the Top Shelf's drift, the screen saver) runs as Core Animation in the
// render server. Driving it from SwiftUI (TimelineView) recomputed and redrew the whole screen up to
// 30 times a second in Mac TV's own process, glass included, for movement no one could see per frame.

/// Pictures decoded for the screen: scaled down to TV size as they're read, and only the last few kept.
@MainActor
enum ScreenImages {
    private struct Key: Hashable {
        let url: URL
        let maxPixels: Int
    }

    private static var cache: [Key: NSImage] = [:]
    private static var order: [Key] = []
    /// The picture on screen, the one fading out, and a couple of thumbnails: no more.
    private static let limit = 3

    /// `maxPixels` is the longest side to decode to: a thumbnail asks for a few hundred, not the full picture.
    static func image(_ url: URL, maxPixels: Int = 1920) -> NSImage? {
        let key = Key(url: url, maxPixels: maxPixels)
        if let cached = cache[key] { return cached }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[key] = image
        order.append(key)
        if order.count > limit { cache[order.removeFirst()] = nil }
        return image
    }
}

/// A picture filling its frame that slowly zooms and drifts left (Apple TV's Top Shelf), from `since`.
struct DriftingPicture: NSViewRepresentable {
    let image: NSImage
    let since: Date
    var zoom: CGFloat = 0.06
    var drift: CGFloat = -18
    var duration: TimeInterval = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        // The decoded bitmap itself: handing the layer an NSImage makes Core Animation keep its own copy.
        view.picture.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        startDrift(on: view.picture)
        return view
    }

    private func startDrift(on picture: CALayer) {
        if !reduceMotion {
            let start = CATransform3DIdentity
            let end = CATransform3DTranslate(CATransform3DMakeScale(1 + zoom, 1 + zoom, 1), drift, 0, 0)
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = start
            animation.toValue = end
            animation.duration = duration
            // Picks up where the drift would be if this view was made part-way through.
            animation.beginTime = CACurrentMediaTime() - min(Date().timeIntervalSince(since), duration)
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            picture.add(animation, forKey: "drift")
        }
    }

    func updateNSView(_ view: LayerView, context: Context) {
        let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        guard let bitmap, view.picture.contents.map({ $0 as AnyObject }) !== bitmap else { return }
        // The next show: Core Animation cross-fades and starts the drift again, so SwiftUI redraws nothing.
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 1.4
        view.picture.add(fade, forKey: "fade")
        view.picture.contents = bitmap
        startDrift(on: view.picture)
    }

    /// A layer-hosting view whose picture layer always fills it.
    final class LayerView: NSView {
        let picture = CALayer()

        init() {
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            layer?.masksToBounds = true
            picture.contentsGravity = .resizeAspectFill
            layer?.addSublayer(picture)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            picture.bounds = bounds
            picture.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
    }
}

/// The photo screen saver: each picture slowly zooms, then cross-fades into the next. A timer swaps
/// pictures every few seconds; everything in between is Core Animation.
struct Slideshow: NSViewRepresentable {
    let files: [URL]
    private static let hold: TimeInterval = 9
    private static let fade: TimeInterval = 1.8

    func makeCoordinator() -> Coordinator { Coordinator(files: files) }

    func makeNSView(context: Context) -> DriftingPicture.LayerView {
        let view = DriftingPicture.LayerView()
        context.coordinator.start(in: view)
        return view
    }

    func updateNSView(_ view: DriftingPicture.LayerView, context: Context) {}

    static func dismantleNSView(_ view: DriftingPicture.LayerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        let files: [URL]
        private var index = 0
        private var timer: Timer?
        private weak var view: NSView?

        init(files: [URL]) { self.files = files }

        func start(in view: NSView) {
            self.view = view
            show(animated: false)
            timer = Timer.scheduledTimer(withTimeInterval: Slideshow.hold, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.show(animated: true) }
            }
        }

        func stop() { timer?.invalidate() }

        private func show(animated: Bool) {
            guard let host = view?.layer, !files.isEmpty,
                  let image = ScreenImages.image(files[index % files.count]) else { index += 1; return }
            index += 1
            let slide = CALayer()
            slide.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            slide.contentsGravity = .resizeAspectFill
            slide.frame = host.bounds
            slide.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            let zoom = CABasicAnimation(keyPath: "transform.scale")
            zoom.fromValue = 1.02
            zoom.toValue = 1.10
            zoom.duration = Slideshow.hold + Slideshow.fade
            zoom.fillMode = .forwards
            zoom.isRemovedOnCompletion = false
            slide.add(zoom, forKey: "zoom")
            if animated {
                let fadeIn = CABasicAnimation(keyPath: "opacity")
                fadeIn.fromValue = 0
                fadeIn.toValue = 1
                fadeIn.duration = Slideshow.fade
                slide.add(fadeIn, forKey: "fade")
            }
            host.addSublayer(slide)
            // Drop slides that are now fully covered.
            let old = (host.sublayers ?? []).filter { $0 !== slide && $0 !== (view as? DriftingPicture.LayerView)?.picture }
            DispatchQueue.main.asyncAfter(deadline: .now() + Slideshow.fade + 0.2) { old.forEach { $0.removeFromSuperlayer() } }
        }
    }
}

/// The fallback screen saver: soft colours drifting slowly across a dark screen, on Core Animation.
struct DriftingColor: NSViewRepresentable {
    private static let palette: [NSColor] = ["#1E3A8A", "#6D28D9", "#0E7490", "#9D174D", "#155E75", "#4338CA"]
        .map { NSColor(Color(hex: $0)) }

    func makeNSView(context: Context) -> NSView {
        let view = GlowView()
        view.layer?.backgroundColor = NSColor(Color(hex: "#05060A")).cgColor
        for (index, color) in Self.palette.enumerated() {
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.colors = [color.withAlphaComponent(0.55).cgColor, color.withAlphaComponent(0).cgColor]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.compositingFilter = "screenBlendMode"
            view.layer?.addSublayer(glow)
            view.glows.append((glow, index))
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Lays the glows out for its size, each wandering on its own slow orbit.
    final class GlowView: NSView {
        var glows: [(layer: CAGradientLayer, index: Int)] = []
        private var laidOut = CGSize.zero

        init() {
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            guard bounds.size != laidOut, bounds.width > 0 else { return }
            laidOut = bounds.size
            let size = bounds.width * 0.9
            for (glow, index) in glows {
                glow.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                let orbit = CGMutablePath()
                orbit.addEllipse(in: CGRect(x: bounds.midX - bounds.width * 0.42, y: bounds.midY - bounds.height * 0.38,
                                            width: bounds.width * 0.84, height: bounds.height * 0.76))
                let wander = CAKeyframeAnimation(keyPath: "position")
                wander.path = orbit
                wander.duration = (38 + Double(index) * 7) * 2 * .pi
                wander.timeOffset = wander.duration * Double(index) / Double(glows.count)
                wander.repeatCount = .infinity
                wander.calculationMode = .paced
                glow.add(wander, forKey: "wander")
            }
        }
    }
}
