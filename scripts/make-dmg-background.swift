// Draws the installer window's background: Mac TV on the left, Applications on the right, an arrow
// between them. Writes Assets/dmg-background.tiff (1x and 2x in one file, for Retina), which make-dmg.sh uses.
//   swift scripts/make-dmg-background.swift [design]               # the backgrounds (Cream unless named)
//   swift scripts/make-dmg-background.swift [design] preview.png   # a preview with both icons in place
//   swift scripts/make-dmg-background.swift variants sheet.png     # every design side by side
import AppKit

let size = NSSize(width: 660, height: 400)
/// Icon centres, from the window's top-left, as Finder places them (make-dmg.sh uses the same numbers).
let appCentre = NSPoint(x: 180, y: 190), applicationsCentre = NSPoint(x: 480, y: 190)

enum Design: String, CaseIterable {
    case midnight, aurora, cream, crt, glass

    var title: String {
        switch self {
        case .midnight: "1  Midnight"
        case .aurora: "2  Aurora"
        case .cream: "3  Cream"
        case .crt: "4  CRT"
        case .glass: "5  Glass"
        }
    }

    /// Finder draws icon names in the viewer's text colour; this is what the design is meant for.
    var labelColor: NSColor { self == .cream || self == .glass ? .black : .white }
}

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func glow(_ centre: NSPoint, _ radius: CGFloat, _ color: NSColor) {
    NSGradient(colors: [color, color.withAlphaComponent(0)])!
        .draw(fromCenter: centre, radius: 0, toCenter: centre, radius: radius, options: [])
}

// MARK: Arrows (y is measured from the bottom, as AppKit draws)

let arrowY = size.height - appCentre.y
let arrowFrom = appCentre.x + 92, arrowTo = applicationsCentre.x - 92

func chevron(_ path: NSBezierPath, at tip: NSPoint, size head: CGFloat = 14) {
    path.move(to: NSPoint(x: tip.x - head, y: tip.y + head))
    path.line(to: tip)
    path.line(to: NSPoint(x: tip.x - head, y: tip.y - head))
}

/// A hand-drawn squiggle that settles into a chevron.
func squiggle(waves: Int = 4, amplitude: CGFloat = 9) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: arrowFrom, y: arrowY))
    let waveEnd = arrowTo - 22
    let width = (waveEnd - arrowFrom) / CGFloat(waves)
    for index in 0..<waves {
        let start = arrowFrom + CGFloat(index) * width, end = start + width
        let lift = (index.isMultiple(of: 2) ? amplitude : -amplitude) * 4 / 3
        path.curve(to: NSPoint(x: end, y: arrowY), controlPoint1: NSPoint(x: start + width / 3, y: arrowY + lift),
                   controlPoint2: NSPoint(x: end - width / 3, y: arrowY + lift))
    }
    path.curve(to: NSPoint(x: arrowTo, y: arrowY), controlPoint1: NSPoint(x: waveEnd + 8, y: arrowY + amplitude * 0.9),
               controlPoint2: NSPoint(x: arrowTo - 8, y: arrowY))
    chevron(path, at: NSPoint(x: arrowTo, y: arrowY))
    return path
}

/// A loop in the middle, like an arrow drawn in one stroke with a pen.
func loop() -> NSBezierPath {
    let path = NSBezierPath()
    let mid = (arrowFrom + arrowTo) / 2
    path.move(to: NSPoint(x: arrowFrom, y: arrowY - 6))
    path.curve(to: NSPoint(x: mid + 10, y: arrowY + 4), controlPoint1: NSPoint(x: arrowFrom + 30, y: arrowY - 16),
               controlPoint2: NSPoint(x: mid - 6, y: arrowY - 20))
    path.curve(to: NSPoint(x: mid - 6, y: arrowY + 10), controlPoint1: NSPoint(x: mid + 26, y: arrowY + 30),
               controlPoint2: NSPoint(x: mid - 18, y: arrowY + 30))
    path.curve(to: NSPoint(x: arrowTo, y: arrowY), controlPoint1: NSPoint(x: mid + 6, y: arrowY - 10),
               controlPoint2: NSPoint(x: arrowTo - 30, y: arrowY - 4))
    chevron(path, at: NSPoint(x: arrowTo, y: arrowY), size: 12)
    return path
}

/// A dashed arc over the gap, the way the icon would be carried across.
func arc() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: arrowFrom - 6, y: arrowY + 34))
    path.curve(to: NSPoint(x: arrowTo + 4, y: arrowY + 30), controlPoint1: NSPoint(x: arrowFrom + 30, y: arrowY + 96),
               controlPoint2: NSPoint(x: arrowTo - 30, y: arrowY + 96))
    return path
}

// MARK: Drawing

func draw(_ design: Design, scale: CGFloat, icons: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(origin: .zero, size: size)
    let centred = NSMutableParagraphStyle()
    centred.alignment = .center
    func caption(_ text: String, _ font: NSFont, _ color: NSColor, y: CGFloat, kern: CGFloat = 0) {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: centred, .kern: kern])
            .draw(in: NSRect(x: 0, y: y, width: size.width, height: font.pointSize * 1.5))
    }
    func stroke(_ path: NSBezierPath, _ color: NSColor, width: CGFloat = 3, dash: [CGFloat] = []) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if !dash.isEmpty { path.setLineDash(dash, count: dash.count, phase: 0) }
        color.setStroke()
        path.stroke()
    }

    switch design {
    case .midnight:
        // Mac TV's home-screen wallpaper: a soft light from the top over near-black.
        colour(0x0A0B0E).setFill(); bounds.fill()
        glow(NSPoint(x: size.width / 2, y: size.height + 60), 620, colour(0x22242F))
        stroke(squiggle(), NSColor(white: 1, alpha: 0.35))
        caption("Drag Mac TV into Applications", .systemFont(ofSize: 15, weight: .medium), NSColor(white: 1, alpha: 0.6), y: 46)

    case .aurora:
        // The screen saver's drifting colours, still: blue, violet and teal light behind the icons.
        colour(0x05060A).setFill(); bounds.fill()
        NSGraphicsContext.current?.compositingOperation = .screen
        glow(NSPoint(x: 140, y: 300), 320, colour(0x1E3A8A, 0.75))
        glow(NSPoint(x: 520, y: 320), 300, colour(0x6D28D9, 0.6))
        glow(NSPoint(x: 340, y: 60), 300, colour(0x0E7490, 0.55))
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        caption("Mac TV", .systemFont(ofSize: 26, weight: .bold), .white, y: 330)
        stroke(squiggle(waves: 3, amplitude: 11), NSColor(white: 1, alpha: 0.7))
        caption("Drag into Applications to install", .systemFont(ofSize: 14, weight: .medium), NSColor(white: 1, alpha: 0.75), y: 46)

    case .cream:
        // The app icon's warm cream, with a pen-drawn loop in its dark brown.
        NSGradient(colors: [colour(0xF8F1E1), colour(0xEFE3C8)])!.draw(in: bounds, angle: -90)
        stroke(loop(), colour(0x3B2F25, 0.7), width: 3.2)
        caption("Drag Mac TV into Applications", .systemFont(ofSize: 15, weight: .semibold), colour(0x3B2F25, 0.75), y: 46)

    case .crt:
        // The icon's screen: green-black glass, faint scan lines, a glowing green squiggle.
        colour(0x050A07).setFill(); bounds.fill()
        glow(NSPoint(x: size.width / 2, y: size.height / 2), 420, colour(0x0F2A1C))
        colour(0x000000, 0.25).setFill()
        for line in stride(from: CGFloat(0), to: size.height, by: 3) { NSRect(x: 0, y: line, width: size.width, height: 1).fill() }
        let green = colour(0x4ADE80)
        stroke(squiggle(waves: 5, amplitude: 8), green.withAlphaComponent(0.25), width: 9)
        stroke(squiggle(waves: 5, amplitude: 8), green.withAlphaComponent(0.9), width: 2.5)
        caption("DRAG MAC TV INTO APPLICATIONS", .monospacedSystemFont(ofSize: 13, weight: .semibold), green.withAlphaComponent(0.85),
                y: 46, kern: 1.5)

    case .glass:
        // Light grey with both icons resting on one frosted panel, and a dashed arc carrying the app across.
        NSGradient(colors: [colour(0xF4F5F8), colour(0xDCDFE6)])!.draw(in: bounds, angle: -90)
        let panel = NSBezierPath(roundedRect: NSRect(x: 60, y: 108, width: 540, height: 196), xRadius: 36, yRadius: 36)
        NSColor(white: 1, alpha: 0.55).setFill(); panel.fill()
        NSColor(white: 1, alpha: 0.9).setStroke(); panel.lineWidth = 1.5; panel.stroke()
        let path = arc()
        stroke(path, colour(0x1D1D1F, 0.45), width: 2.5, dash: [1, 8])
        let tip = NSBezierPath()
        tip.move(to: NSPoint(x: arrowTo - 8, y: arrowY + 44))
        tip.line(to: NSPoint(x: arrowTo + 4, y: arrowY + 30))
        tip.line(to: NSPoint(x: arrowTo - 14, y: arrowY + 26))
        stroke(tip, colour(0x1D1D1F, 0.45), width: 2.5)
        caption("Drag Mac TV into Applications", .systemFont(ofSize: 15, weight: .medium), colour(0x1D1D1F, 0.7), y: 52)
    }

    if icons {
        let iconSize: CGFloat = 128
        for (centre, image, label) in [(appCentre, NSImage(contentsOfFile: "Assets/AppIcon.png")!, "Mac TV"),
                                       (applicationsCentre, NSWorkspace.shared.icon(forFile: "/Applications"), "Applications")] {
            let c = NSPoint(x: centre.x, y: size.height - centre.y)
            image.draw(in: NSRect(x: c.x - iconSize / 2, y: c.y - iconSize / 2, width: iconSize, height: iconSize))
            NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: design.labelColor, .paragraphStyle: centred,
            ]).draw(in: NSRect(x: c.x - 80, y: c.y - iconSize / 2 - 24, width: 160, height: 18))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Every design in a grid, each named underneath, for choosing one.
func variantsSheet() -> NSBitmapImageRep {
    let columns = 2, gap: CGFloat = 40, labelHeight: CGFloat = 44
    let rows = (Design.allCases.count + columns - 1) / columns
    let sheet = NSSize(width: CGFloat(columns) * size.width + CGFloat(columns + 1) * gap,
                       height: CGFloat(rows) * (size.height + labelHeight) + CGFloat(rows + 1) * gap)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(sheet.width * 2), pixelsHigh: Int(sheet.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = sheet
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    colour(0x2A2B30).setFill(); NSRect(origin: .zero, size: sheet).fill()
    for (index, design) in Design.allCases.enumerated() {
        let column = index % columns, row = index / columns
        let x = gap + CGFloat(column) * (size.width + gap)
        let top = gap + CGFloat(row) * (size.height + labelHeight + gap)
        let frame = NSRect(x: x, y: sheet.height - top - size.height, width: size.width, height: size.height)
        let image = NSImage(size: size)
        image.addRepresentation(draw(design, scale: 2, icons: true))
        NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).addClip()
        image.draw(in: frame)
        NSGraphicsContext.current?.cgContext.resetClip()
        NSAttributedString(string: design.title, attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white,
        ]).draw(at: NSPoint(x: x + 4, y: frame.minY - 32))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "variants" {
    write(variantsSheet(), arguments.count > 1 ? arguments[1] : "variants.png")
} else {
    let design = arguments.first.flatMap(Design.init(rawValue:)) ?? .cream
    if Design(rawValue: arguments.first ?? "") != nil { arguments.removeFirst() }
    if let preview = arguments.first {
        write(draw(design, scale: 2, icons: true), preview)
    } else {
        let folder = FileManager.default.temporaryDirectory.path
        write(draw(design, scale: 1, icons: false), folder + "/dmg-background.png")
        write(draw(design, scale: 2, icons: false), folder + "/dmg-background@2x.png")
        let join = Process()
        join.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
        join.arguments = ["-cathidpicheck", folder + "/dmg-background.png", folder + "/dmg-background@2x.png",
                          "-out", "Assets/dmg-background.tiff"]
        try! join.run()
        join.waitUntilExit()
    }
}
