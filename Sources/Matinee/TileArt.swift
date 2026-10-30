import AppKit

/// Turns any square app icon into a 5:3 dock tile in Apple TV's style: one brand ground and
/// one centred mark, every mark at the same optical size. Works without per-app tuning:
///
/// 1. Read the icon's ground from just inside its corners (past rims and rounded corners; for
///    icons with transparent corners, like macOS app icons, from inside the shape).
/// 2. Find the mark: the pixels that differ from that ground, as a bounding box.
/// 3. Scale the mark to a fixed visual area, capped in height and width, and centre it.
/// 4. Paint the ground across the tile by continuing the icon's corner colours outward, then
///    lay the mark (with a margin of its own ground) on top, its cut edges faded away.
enum TileArt {
    /// Tile size in pixels (2× the 250×150 point tile).
    static let size = CGSize(width: 500, height: 300)
    /// Every mark is scaled to cover about this many square pixels of the tile…
    private static let markArea: CGFloat = 22_000
    /// …but never taller or wider than these.
    private static let maxMark = CGSize(width: 320, height: 190)
    /// Ground pixels kept around the mark, in icon units.
    private static let margin: CGFloat = 0.045

    static func make(from icon: CGImage) -> NSImage? {
        guard let pixels = Pixels(icon, side: 256) else { return nil }

        // 1. The ground, from inside the corners: past the glass rim many App Store icons
        //    carry, or inside the shape when the corners are transparent.
        let opaqueCorners = pixels.alpha(0.06, 0.06) > 0.5 && pixels.alpha(0.94, 0.94) > 0.5
        let sampleInset: CGFloat = opaqueCorners ? 0.12 : 0.22
        let ground = Ground(pixels: pixels, inset: sampleInset)

        // 2. The mark's bounding box, searched inside the area the ground was read from.
        let searchInset = sampleInset - 0.02
        let mark = pixels.boundingBox(differingFrom: ground, inset: searchInset)
            ?? CGRect(x: searchInset, y: searchInset, width: 1 - 2 * searchInset, height: 1 - 2 * searchInset)

        // 3. Scale (tile pixels per icon unit) and placement: the mark's centre at the tile's centre.
        var scale = (markArea / (mark.width * mark.height)).squareRoot()
        scale = min(scale, maxMark.width / mark.width, maxMark.height / mark.height)
        let toTile = { (u: CGFloat, v: CGFloat) -> CGPoint in
            CGPoint(x: size.width / 2 + (u - mark.midX) * scale, y: size.height / 2 + (v - mark.midY) * scale)
        }

        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high

        // 4a. The ground, continued across the whole tile.
        let topV = mark.midY - (size.height / 2) / scale, bottomV = mark.midY + (size.height / 2) / scale
        for x in 0..<Int(size.width) {
            let u = mark.midX + (CGFloat(x) + 0.5 - size.width / 2) / scale
            // CG's y axis points up: the bottom of the tile is y = 0.
            guard let column = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          colors: [ground.color(u, bottomV), ground.color(u, topV)] as CFArray,
                                          locations: [0, 1]) else { continue }
            context.saveGState()
            context.clip(to: CGRect(x: CGFloat(x), y: 0, width: 1, height: size.height))
            context.drawLinearGradient(column, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            context.restoreGState()
        }

        // 4b. The mark with a margin of ground, edges faded so no cut line shows.
        // A shaded ground needs a wider margin to fade across without a visible edge.
        let margin = ground.isFlat ? margin : margin * 2.2
        // Icons with transparent corners (macOS app icons) are searched well inside their shape,
        // so let the crop reach nearer the shape's edge rather than cut a mark that extends there.
        let limit = opaqueCorners ? searchInset : 0.13
        let crop = CGRect(x: max(mark.minX - margin, limit), y: max(mark.minY - margin, limit),
                          width: 0, height: 0)
        let cropMax = CGPoint(x: min(mark.maxX + margin, 1 - limit), y: min(mark.maxY + margin, 1 - limit))
        let unit = CGRect(x: crop.minX, y: crop.minY, width: cropMax.x - crop.minX, height: cropMax.y - crop.minY)
        let w = CGFloat(icon.width), h = CGFloat(icon.height)
        guard let piece = icon.cropping(to: CGRect(x: unit.minX * w, y: unit.minY * h,
                                                   width: unit.width * w, height: unit.height * h))
        else { return nil }
        let topLeft = toTile(unit.minX, unit.minY)
        let target = CGRect(x: topLeft.x, y: size.height - topLeft.y - unit.height * scale,
                            width: unit.width * scale, height: unit.height * scale)
        if ground.isFlat {
            // One colour all round: the piece's edges already match, so keep the mark crisp.
            context.draw(piece, in: target)
        } else if let faded = fade(piece, size: target.size, edge: margin * scale * 0.8) {
            context.draw(faded, in: target)
        }

        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: size.width / 2, height: size.height / 2))
    }

    /// The icon's brand colour as hex: the mark's average colour, or the ground's when the
    /// mark is white, black or grey (Netflix's red, Spotify's green, Prime's blue).
    static func brandColor(from icon: CGImage) -> String? {
        guard let pixels = Pixels(icon, side: 128) else { return nil }
        let opaqueCorners = pixels.alpha(0.06, 0.06) > 0.5 && pixels.alpha(0.94, 0.94) > 0.5
        let inset: CGFloat = opaqueCorners ? 0.12 : 0.22
        let ground = Ground(pixels: pixels, inset: inset)
        let saturation = { (c: [CGFloat]) -> CGFloat in (c.max() ?? 0) - (c.min() ?? 0) }
        var color = pixels.averageColor(differingFrom: ground, inset: inset - 0.02)
        if color.map(saturation) ?? 0 < 0.2 { color = ground.components(0.5, 0.5) }
        guard let color, saturation(color) >= 0.15 else { return nil }
        return String(format: "#%02X%02X%02X", Int(color[0] * 255), Int(color[1] * 255), Int(color[2] * 255))
    }

    /// The image drawn at `size` with `edge` points at each side faded to transparent.
    private static func fade(_ image: CGImage, size: CGSize, edge: CGFloat) -> CGImage? {
        let width = max(Int(size.width.rounded()), 1), height = max(Int(size.height.rounded()), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.destinationIn)
        for (length, end) in [(CGFloat(width), CGPoint(x: width, y: 0)), (CGFloat(height), CGPoint(x: 0, y: height))] {
            let f = min(edge / length, 0.45)
            let clear = CGColor(red: 0, green: 0, blue: 0, alpha: 0), solid = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            colors: [clear, solid, solid, clear] as CFArray,
                                            locations: [0, f, 1 - f, 1]) else { continue }
            context.drawLinearGradient(gradient, start: .zero, end: end, options: [])
        }
        return context.makeImage()
    }
}

/// The icon drawn into sRGB at a fixed size, for reading colours exactly as they'll be drawn.
private struct Pixels {
    let side: Int
    private let data: [UInt8]

    init?(_ image: CGImage, side: Int) {
        var data = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        self.side = side
        self.data = data
    }

    private func index(_ u: CGFloat, _ v: CGFloat) -> Int {
        let x = min(max(Int(u * CGFloat(side - 1)), 0), side - 1)
        let y = min(max(Int(v * CGFloat(side - 1)), 0), side - 1) // memory starts at the top row
        return (y * side + x) * 4
    }

    func alpha(_ u: CGFloat, _ v: CGFloat) -> CGFloat { CGFloat(data[index(u, v) + 3]) / 255 }

    /// Un-premultiplied sRGB, or nil where the icon is mostly transparent.
    func rgb(_ u: CGFloat, _ v: CGFloat) -> [CGFloat]? {
        let i = index(u, v), a = CGFloat(data[i + 3]) / 255
        guard a > 0.5 else { return nil }
        return (0..<3).map { CGFloat(data[i + $0]) / 255 / a }
    }

    /// The average colour of pixels that stand out from the ground.
    func averageColor(differingFrom ground: Ground, inset: CGFloat) -> [CGFloat]? {
        let lo = Int(inset * CGFloat(side)), hi = side - lo
        var total: [CGFloat] = [0, 0, 0], count: CGFloat = 0
        for y in lo..<hi {
            for x in lo..<hi {
                let u = CGFloat(x) / CGFloat(side - 1), v = CGFloat(y) / CGFloat(side - 1)
                guard let pixel = rgb(u, v) else { continue }
                if zip(pixel, ground.components(u, v)).map({ abs($0 - $1) }).max() ?? 0 > 0.16 {
                    total = zip(total, pixel).map(+)
                    count += 1
                }
            }
        }
        return count > 0 ? total.map { $0 / count } : nil
    }

    /// The box around pixels that stand out from the ground, ignoring specks.
    func boundingBox(differingFrom ground: Ground, inset: CGFloat) -> CGRect? {
        let lo = Int(inset * CGFloat(side)), hi = side - lo
        var rows = [Int](repeating: 0, count: side), columns = [Int](repeating: 0, count: side)
        for y in lo..<hi {
            for x in lo..<hi {
                let u = CGFloat(x) / CGFloat(side - 1), v = CGFloat(y) / CGFloat(side - 1)
                guard let pixel = rgb(u, v) else { continue }
                let expected = ground.components(u, v)
                let difference = zip(pixel, expected).map { abs($0 - $1) }.max() ?? 0
                if difference > 0.16 {
                    rows[y] += 1
                    columns[x] += 1
                }
            }
        }
        let minimum = 2
        guard let top = rows.firstIndex(where: { $0 >= minimum }), let bottom = rows.lastIndex(where: { $0 >= minimum }),
              let left = columns.firstIndex(where: { $0 >= minimum }), let right = columns.lastIndex(where: { $0 >= minimum })
        else { return nil }
        let n = CGFloat(side - 1)
        return CGRect(x: CGFloat(left) / n, y: CGFloat(top) / n,
                      width: CGFloat(right - left + 1) / n, height: CGFloat(bottom - top + 1) / n)
    }
}

/// The icon's background as a bilinear blend of four colours read just inside its corners.
/// Coordinates are icon units (0…1, top-left origin); outside the icon it extrapolates.
private struct Ground {
    let inset: CGFloat
    /// Top-left, top-right, bottom-left, bottom-right.
    let corners: [[CGFloat]]

    init(pixels: Pixels, inset: CGFloat) {
        self.inset = inset
        corners = [(inset, inset), (1 - inset, inset), (inset, 1 - inset), (1 - inset, 1 - inset)].map {
            pixels.rgb($0.0, $0.1) ?? [0, 0, 0]
        }
    }

    /// True when all four corners are the same colour, give or take.
    var isFlat: Bool {
        corners.allSatisfy { corner in zip(corner, corners[0]).allSatisfy { abs($0 - $1) < 0.03 } }
    }

    func components(_ u: CGFloat, _ v: CGFloat) -> [CGFloat] {
        // Continue a gradient a little past the sampled square, then hold it, so small
        // differences between corners don't grow into stripes at the tile's far edges.
        let reach: CGFloat = 0.5
        let s = min(max((u - inset) / (1 - 2 * inset), -reach), 1 + reach)
        let t = min(max((v - inset) / (1 - 2 * inset), -reach), 1 + reach)
        return (0..<3).map { i in
            let top = corners[0][i] + (corners[1][i] - corners[0][i]) * s
            let bottom = corners[2][i] + (corners[3][i] - corners[2][i]) * s
            return min(max(top + (bottom - top) * t, 0), 1)
        }
    }

    func color(_ u: CGFloat, _ v: CGFloat) -> CGColor {
        let c = components(u, v)
        return CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
    }
}
