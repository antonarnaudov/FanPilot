// Renders the app icon on Apple's macOS icon grid: a continuous-corner squircle
// (superellipse) filling 824 of 1024 points, a soft drop shadow, a blue gradient
// with a top sheen, and a white fan glyph.
// usage: swift scripts/make-icon.swift Resources/AppIcon.icns [preview.png]
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"
let preview = CommandLine.arguments.dropFirst(2).first
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FanPilot.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// A superellipse |x/a|^n + |y/b|^n = 1, the shape of macOS app icons.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * a * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * b * (s < 0 ? -1 : 1)
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let scale = s / 1024

    // Icon grid: 824 × 824 body, centred slightly high to leave room for the shadow.
    let body = CGRect(x: 100 * scale, y: 112 * scale, width: 824 * scale, height: 824 * scale)
    let shape = squircle(in: body)

    // Drop shadow.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale,
                 color: NSColor.black.withAlphaComponent(0.32).cgColor)
    cg.addPath(shape)
    cg.setFillColor(NSColor.black.cgColor)
    cg.fillPath()
    cg.restoreGState()

    // Body gradient: sky blue at the top to deep blue at the bottom.
    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let colors = [
        NSColor(srgbRed: 0.36, green: 0.78, blue: 1.00, alpha: 1).cgColor,
        NSColor(srgbRed: 0.05, green: 0.44, blue: 0.96, alpha: 1).cgColor,
        NSColor(srgbRed: 0.10, green: 0.22, blue: 0.70, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: body.midX, y: body.maxY),
                          end: CGPoint(x: body.midX, y: body.minY), options: [])

    // Sheen on the top half.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.28).cgColor,
                                    NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
    cg.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY),
                          end: CGPoint(x: body.midX, y: body.midY), options: [])

    // Fine inner edge highlight.
    cg.addPath(squircle(in: body.insetBy(dx: 1.5 * scale, dy: 1.5 * scale)))
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
    cg.setLineWidth(3 * scale)
    cg.strokePath()
    cg.restoreGState()

    // Fan glyph with a soft shadow.
    let config = NSImage.SymbolConfiguration(pointSize: 430 * scale, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let glyph = symbol.size
        let rect = CGRect(x: body.midX - glyph.width / 2, y: body.midY - glyph.height / 2,
                          width: glyph.width, height: glyph.height)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 20 * scale,
                     color: NSColor(srgbRed: 0, green: 0.1, blue: 0.4, alpha: 0.45).cgColor)
        symbol.draw(in: rect)
        cg.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let preview { try render(512).write(to: URL(fileURLWithPath: preview)) }

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "wrote \(output)" : "iconutil failed")
