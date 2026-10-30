// Draws Mac TV's app icon and builds AppIcon.icns.
//   swift scripts/make-icon.swift            → Assets/AppIcon.png and Assets/AppIcon.icns
//
// The design: a chunky retro CRT whose phosphor screen glows with the Mac ⌘ symbol.
//
// Built on Apple's macOS icon grid:
// - 1024 px canvas; the icon body is the 824 px squircle inset 100 px on every side.
// - The squircle is a quintic superellipse (|x|⁵ + |y|⁵ = 1), close to Apple's continuous corners.
// - Nothing is drawn outside the squircle, not even a drop shadow: macOS adds its own, and
//   macOS 26 puts icons with pixels outside the shape on a grey backing plate.
// - The TV sits centred with equal margins: 80 px left and right, 142 px top and bottom
//   (feet included), measured from the squircle's edges.
// - Small sizes (64 px and under) drop fine detail so they stay crisp.

import AppKit

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { color($0.0, $0.1) } as CFArray, locations: stops.map(\.2))!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Apple-style squircle: a quintic superellipse filling `rect`.
func squircle(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + rect.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / 5)
        let y = rect.midY + rect.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / 5)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func vertical(_ ctx: CGContext, _ grad: CGGradient, top: CGFloat, bottom: CGFloat) {
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
}

func render(size: Int) -> CGImage {
    let detailed = size > 64
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    ctx.interpolationQuality = .high

    // Everything is clipped to the squircle.
    ctx.addPath(squircle(body))
    ctx.clip()

    // Ground: warm cream, lighter at the top.
    vertical(ctx, gradient([(0xF6EEDD, 1, 0), (0xE9DCC0, 1, 0.6), (0xDCCAA5, 1, 1)]), top: body.maxY, bottom: body.minY)

    // Layout (CG coordinates, y up).
    let tv = CGRect(x: 180, y: 282, width: 664, height: 500)
    let screen = CGRect(x: 222, y: 324, width: 466, height: 416)
    // Centre of the panel between the bezel (700) and the cabinet edge (844).
    let panelX: CGFloat = 772

    // Contact shadow: a flat ellipse right under the feet.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 244)
    ctx.scaleBy(x: 1, y: 0.12)
    ctx.drawRadialGradient(gradient([(0x5A4326, 0.38, 0), (0x5A4326, 0, 1)]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 360, options: [])
    ctx.restoreGState()

    // Feet.
    for x in [262.0, 712.0] {
        ctx.addPath(roundedRect(CGRect(x: x, y: 242, width: 50, height: 56), 16))
        ctx.setFillColor(color(0x2A221B))
        ctx.fillPath()
    }

    // Cabinet: charcoal with a soft top light and a crisp lit edge.
    let cabinet = roundedRect(tv, 96)
    ctx.saveGState()
    ctx.addPath(cabinet)
    ctx.clip()
    vertical(ctx, gradient([(0x4A4A50, 1, 0), (0x2B2B30, 1, 0.45), (0x1C1C20, 1, 1)]), top: tv.maxY, bottom: tv.minY)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(cabinet)
    ctx.setLineWidth(6)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    vertical(ctx, gradient([(0xFFFFFF, 0.28, 0), (0xFFFFFF, 0.0, 0.5)]), top: tv.maxY, bottom: tv.minY)
    ctx.restoreGState()

    // Bezel around the glass.
    ctx.addPath(roundedRect(screen.insetBy(dx: -12, dy: -12), 104))
    ctx.setFillColor(color(0x121214))
    ctx.fillPath()

    // CRT glass: deep phosphor green, lighter at the centre, darker at the curved edges.
    let glass = roundedRect(screen, 92)
    ctx.saveGState()
    ctx.addPath(glass)
    ctx.clip()
    ctx.setFillColor(color(0x020A05))
    ctx.fill(screen)
    ctx.drawRadialGradient(gradient([(0x0F3A20, 1, 0), (0x062012, 1, 0.55), (0x020A05, 1, 1)]),
                           startCenter: CGPoint(x: screen.midX, y: screen.midY), startRadius: 0,
                           endCenter: CGPoint(x: screen.midX, y: screen.midY), endRadius: 300, options: [])

    if detailed {
        // Faint scanlines behind the glyph, so the ⌘ itself stays one clean shape.
        ctx.setFillColor(color(0x000000, 0.22))
        var y = screen.minY
        while y < screen.maxY {
            ctx.fill(CGRect(x: screen.minX, y: y, width: screen.width, height: 3))
            y += 8
        }
    }

    // The ⌘, glowing: a wide bloom, then a bright core.
    let glyphSize: CGFloat = detailed ? 250 : 290
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: glyphSize, weight: detailed ? .semibold : .heavy),
        .foregroundColor: NSColor(cgColor: color(0xA6FFCB))!,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "⌘", attributes: attributes))
    let ink = CTLineGetImageBounds(line, ctx)
    let origin = CGPoint(x: screen.midX - ink.midX, y: screen.midY - ink.midY)
    for (blur, alpha) in [(46.0, 0.7), (16.0, 0.9)] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: blur, color: color(0x2BFF7E, alpha))
        ctx.textPosition = origin
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // Curved glass reflection, top left.
    ctx.drawRadialGradient(gradient([(0xFFFFFF, 0.16, 0), (0xFFFFFF, 0, 1)]),
                           startCenter: CGPoint(x: screen.minX + 110, y: screen.maxY - 80), startRadius: 0,
                           endCenter: CGPoint(x: screen.minX + 110, y: screen.maxY - 80), endRadius: 230, options: [])
    ctx.restoreGState()

    // Control panel: two brass knobs and a speaker grille, centred on one axis.
    for y in [652.0, 548.0] {
        let knob = CGRect(x: panelX - 38, y: y - 38, width: 76, height: 76)
        ctx.saveGState()
        ctx.addEllipse(in: knob)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0xE8C88A, 1, 0), (0xB88E4E, 1, 0.55), (0x7E5E2E, 1, 1)]),
                               start: CGPoint(x: knob.minX, y: knob.maxY), end: CGPoint(x: knob.maxX, y: knob.minY), options: [])
        ctx.restoreGState()
        ctx.addEllipse(in: knob.insetBy(dx: 18, dy: 18))
        ctx.setFillColor(color(0x6E5228))
        ctx.fillPath()
        // Pointer.
        ctx.addPath(roundedRect(CGRect(x: panelX - 4, y: y + 6, width: 8, height: 22), 4))
        ctx.setFillColor(color(0xF6E2B4))
        ctx.fillPath()
    }
    if detailed {
        for i in 0..<5 {
            ctx.addPath(roundedRect(CGRect(x: panelX - 34, y: 344 + CGFloat(i) * 22, width: 68, height: 9), 4.5))
            ctx.setFillColor(color(0x0E0E10))
            ctx.fillPath()
        }
    }

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
