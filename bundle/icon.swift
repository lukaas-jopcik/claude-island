// Renders the Claude Island app icon (a dark squircle with a glowing island pill) into an .iconset.
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let body = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.19, green: 0.17, blue: 0.27, alpha: 1), NSColor(srgbRed: 0.07, green: 0.07, blue: 0.11, alpha: 1)])!
        .draw(in: body, angle: -90)
    // glow
    body.addClip()
    let glow = NSGradient(colors: [NSColor(srgbRed: 0.80, green: 0.65, blue: 0.97, alpha: 0.75), NSColor(srgbRed: 0.54, green: 0.71, blue: 0.98, alpha: 0)])!
    glow.draw(fromCenter: NSPoint(x: s / 2, y: s * 0.62), radius: 0, toCenter: NSPoint(x: s / 2, y: s * 0.62), radius: s * 0.42, options: [])
    // island pill
    let pw = r.width * 0.56, ph = r.width * 0.17
    let pill = NSBezierPath(roundedRect: NSRect(x: s / 2 - pw / 2, y: s * 0.62 - ph / 2, width: pw, height: ph), xRadius: ph / 2, yRadius: ph / 2)
    NSColor.black.setFill(); pill.fill()
    NSColor(white: 1, alpha: 0.18).setStroke(); pill.lineWidth = max(1, s * 0.006); pill.stroke()
    // dot inside the pill
    let d = ph * 0.42
    let dot = NSBezierPath(ovalIn: NSRect(x: s / 2 + pw / 2 - ph * 0.5 - d / 2, y: s * 0.62 - d / 2, width: d, height: d))
    NSColor(srgbRed: 0.80, green: 0.65, blue: 0.97, alpha: 1).setFill(); dot.fill()
    // three task lines below
    for i in 0..<3 {
        let y = s * 0.40 - CGFloat(i) * s * 0.085, w = r.width * (i == 2 ? 0.34 : 0.5)
        let line = NSBezierPath(roundedRect: NSRect(x: s / 2 - r.width * 0.25, y: y, width: w, height: s * 0.035), xRadius: s * 0.0175, yRadius: s * 0.0175)
        NSColor(white: 1, alpha: i == 0 ? 0.55 : 0.28).setFill(); line.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
