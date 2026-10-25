// Renders the app icon into an .iconset folder: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824pt body centered on a 1024 canvas.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    shape.fill()
    ctx.restoreGState()

    ctx.saveGState()
    shape.addClip()
    NSGradient(colors: [NSColor(red: 0.10, green: 0.42, blue: 1.0, alpha: 1),
                        NSColor(red: 0.42, green: 0.20, blue: 0.86, alpha: 1)])!
        .draw(in: body, angle: -55)

    // Faint stacked slice planes behind the glyph.
    for i in 0..<3 {
        let inset = CGFloat(150 + i * 70) * s
        let r = body.insetBy(dx: inset * 0.55, dy: inset * 0.55).offsetBy(dx: 0, dy: CGFloat(i - 1) * 46 * s)
        let p = NSBezierPath(roundedRect: r, xRadius: 60 * s, yRadius: 60 * s)
        NSColor.white.withAlphaComponent(0.05 + CGFloat(i) * 0.02).setFill()
        p.fill()
    }
    // Top sheen.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    ctx.restoreGState()

    let config = NSImage.SymbolConfiguration(pointSize: 430 * s, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "lungs.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        let rect = CGRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2 - 6 * s,
                          width: size.width, height: size.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s,
                      color: NSColor.black.withAlphaComponent(0.3).cgColor)
        symbol.draw(in: rect)
        ctx.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
