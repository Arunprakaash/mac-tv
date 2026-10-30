// Draws Mac TV's app icon and builds AppIcon.icns.
//   swift scripts/make-icon.swift            → Assets/AppIcon.png and Assets/AppIcon.icns
//
// The design: an afternoon show. A glowing screen with a warm sunset gradient and a soft
// white play symbol, on a deep twilight ground, in the macOS rounded-square shape.

import AppKit

let canvas: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824) // Apple's macOS icon grid
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { color($0.0, $0.1) } as CFArray,
               locations: stops.map(\.2))!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    ctx.interpolationQuality = .high

    let shape = roundedRect(tile, 185)

    // Soft shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x15112E))
    ctx.fillPath()
    ctx.restoreGState()

    // Twilight ground.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0x2B2266, 1, 0), (0x15112E, 1, 0.55), (0x0A0816, 1, 1)]),
                           start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
    // Warm glow rising behind the screen.
    ctx.drawRadialGradient(gradient([(0xFF7A59, 0.55, 0), (0xFF7A59, 0, 1)]),
                           startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 470), endRadius: 430, options: [])
    ctx.restoreGState()

    // The screen.
    let screen = CGRect(x: 512 - 290, y: 400, width: 580, height: 380)
    let screenPath = roundedRect(screen, 70)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x000000, 0.45))
    ctx.addPath(screenPath)
    ctx.setFillColor(color(0xFF6A5C))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    // Sunset: gold at the top, coral, then magenta.
    ctx.drawLinearGradient(gradient([(0xFFC65A, 1, 0), (0xFF7A59, 1, 0.5), (0xC93A8E, 1, 1)]),
                           start: CGPoint(x: 512, y: screen.maxY), end: CGPoint(x: 512, y: screen.minY), options: [])
    // A low sun on the horizon.
    ctx.drawRadialGradient(gradient([(0xFFF1C9, 0.9, 0), (0xFFE29A, 0.35, 0.45), (0xFFE29A, 0, 1)]),
                           startCenter: CGPoint(x: 512, y: screen.minY + 150), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: screen.minY + 150), endRadius: 260, options: [])
    // Glass sheen across the top half.
    ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.28, 0), (0xFFFFFF, 0.0, 0.55)]),
                           start: CGPoint(x: 512, y: screen.maxY), end: CGPoint(x: 512, y: screen.minY), options: [])
    ctx.restoreGState()

    // A thin lit edge on the screen.
    ctx.addPath(screenPath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.35))
    ctx.setLineWidth(3)
    ctx.strokePath()

    // Play symbol with rounded corners.
    let play = CGMutablePath()
    let cx: CGFloat = 524, cy = screen.midY
    play.move(to: CGPoint(x: cx - 62, y: cy + 82))
    play.addLine(to: CGPoint(x: cx + 86, y: cy))
    play.addLine(to: CGPoint(x: cx - 62, y: cy - 82))
    play.closeSubpath()
    // Drawn as one layer so the shadow falls outside the symbol, not into it.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x7A1E52, 0.45))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(play)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(34)
    ctx.setLineJoin(.round)
    ctx.drawPath(using: .fillStroke)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // The stand: a soft bar beneath the screen.
    ctx.addPath(roundedRect(CGRect(x: 512 - 120, y: 318, width: 240, height: 26), 13))
    ctx.setFillColor(color(0xFFFFFF, 0.55))
    ctx.fillPath()

    // Glass rim on the tile: bright at the top, fading down.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(4)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.45, 0), (0xFFFFFF, 0.05, 0.6)]),
                           start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func png(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

try png(render(size: 1024)).write(to: assets.appendingPathComponent("AppIcon.png"))
for base in [16, 32, 128, 256, 512] {
    try png(render(size: base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(render(size: base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Assets/AppIcon.png and Assets/AppIcon.icns" : "iconutil failed")
