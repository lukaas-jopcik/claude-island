// Full-screen backdrop that hides the desktop and menu bar while the demo is recorded.
// Sits one level under the island, so only the island is drawn over it. Quit with Ctrl-C.
import AppKit

final class Backdrop: NSView {
    override func draw(_ r: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        let cs = CGColorSpaceCreateDeviceRGB()
        let g = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.13, green: 0.12, blue: 0.20, alpha: 1),
                                                     CGColor(red: 0.05, green: 0.05, blue: 0.09, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: bounds.height), end: CGPoint(x: bounds.width, y: 0), options: [])
        func orb(_ x: CGFloat, _ y: CGFloat, _ rad: CGFloat, _ c: CGColor) {
            let og = CGGradient(colorsSpace: cs, colors: [c, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(og, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: rad, options: [])
        }
        orb(bounds.midX - 260, bounds.height - 120, 520, CGColor(red: 0.80, green: 0.65, blue: 0.97, alpha: 0.30))   // mauve
        orb(bounds.midX + 300, bounds.height - 260, 560, CGColor(red: 0.54, green: 0.71, blue: 0.98, alpha: 0.26))   // blue
        orb(bounds.midX, bounds.height - 600, 700, CGColor(red: 0.58, green: 0.89, blue: 0.84, alpha: 0.10))         // teal
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
w.isOpaque = true
w.hasShadow = false
w.contentView = Backdrop(frame: NSRect(origin: .zero, size: screen.frame.size))
w.setFrame(screen.frame, display: true)
w.orderFrontRegardless()
print("screen frame", screen.frame, "scale", screen.backingScaleFactor, "notch inset", screen.safeAreaInsets.top)
app.run()
