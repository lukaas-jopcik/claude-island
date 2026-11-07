// GlassToast — a Liquid Glass notification toast for Claude Code hooks.
// Usage: glass-toast --kind input|permission|done --title T --message M
//        [--project P] [--term TERM_PROGRAM] [--session ID] [--match a,b] [--duration S]
// --session: a newer toast for the same session replaces the older one.
// --match:   skip the toast when the terminal app is frontmost and its window title contains one of these.
import AppKit

// MARK: - Arguments

struct Args {
    var kind = "input"
    var title = "Claude"
    var message = ""
    var project = ""
    var term = ""
    var session = ""
    var match: [String] = []
    var duration: Double = 5
    var checkOnly = false

    init() {
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let key = it.next() {
            let value = it.next() ?? ""
            switch key {
            case "--kind": kind = value
            case "--title": title = value
            case "--message": message = value
            case "--project": project = value
            case "--term": term = value
            case "--session": session = value.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            case "--match": match = value.split(separator: ",").map(String.init).filter { $0.count > 1 }
            case "--duration": duration = Double(value) ?? duration
            case "--check-only": checkOnly = value == "1"
            default: break
            }
        }
    }
}

let terminalBundleIDs: [String: String] = [
    "ghostty": "com.mitchellh.ghostty",
    "zed": "dev.zed.Zed",
    "Apple_Terminal": "com.apple.Terminal",
    "iTerm.app": "com.googlecode.iterm2",
    "vscode": "com.microsoft.VSCode",
    "WarpTerminal": "dev.warp.Warp-Stable",
]

// MARK: - Palette (Catppuccin Mocha, matches Zed / Ghostty)

enum Palette {
    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: a)
    }
    static let crust = hex(0x11111b)
    static let text = hex(0xcdd6f4)
    static let subtext = hex(0xa6adc8)
    static let overlay = hex(0x7f849c)
    static let mauve = hex(0xcba6f7)
    static let green = hex(0xa6e3a1)
    static let peach = hex(0xfab387)
}

// MARK: - Visibility check

/// True when the session's terminal is the frontmost app and its focused window looks like this session.
func userIsLookingAtSession(_ args: Args) -> Bool {
    guard let id = terminalBundleIDs[args.term],
          let front = NSWorkspace.shared.frontmostApplication,
          front.bundleIdentifier == id else { return false }
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
    // windows come front-to-back; take the first normal window of the frontmost app
    let win = list.first {
        ($0[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier
            && ($0[kCGWindowLayer as String] as? Int) == 0
            && !(($0[kCGWindowName as String] as? String) ?? "").isEmpty
    }
    guard let title = win?[kCGWindowName as String] as? String, !title.isEmpty else {
        // title unreadable: only suppress the low-priority "done" toast
        return args.kind == "done"
    }
    return args.match.contains { title.localizedCaseInsensitiveContains($0) }
}

// MARK: - Slots (stack several toasts without overlap) and per-session replacement

let notifierDir = NSString(string: "~/.claude/notifier").expandingTildeInPath
// C strings so the SIGTERM handler can clean up without touching Swift objects
var cSlotPid: UnsafeMutablePointer<CChar>? = nil
var cSlotDir: UnsafeMutablePointer<CChar>? = nil
var cSessionFile: UnsafeMutablePointer<CChar>? = nil

func cleanupFiles() {
    if let p = cSlotPid { unlink(p) }
    if let p = cSlotDir { rmdir(p) }
    if let p = cSessionFile { unlink(p) }
}

func readPid(_ path: String) -> Int32? {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Ask an older toast of the same session to go away and wait briefly for it to free its slot.
func replacePreviousToast(session: String) {
    guard !session.isEmpty else { return }
    let dir = "\(notifierDir)/sessions"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let file = "\(dir)/\(session)"
    if let old = readPid(file), old != getpid(), kill(old, 0) == 0 {
        kill(old, SIGTERM)
        for _ in 0..<30 where kill(old, 0) == 0 { usleep(10_000) }
    }
    try? "\(getpid())".write(toFile: file, atomically: true, encoding: .utf8)
    cSessionFile = strdup(file)
}

final class Slot {
    let index: Int

    init() {
        let dir = "\(notifierDir)/slots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for i in 0..<7 {
            let p = "\(dir)/\(i)"
            // stale slot: owner process is gone
            if let pid = readPid("\(p)/pid"), kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(atPath: p)
            }
            if mkdir(p, 0o755) == 0 {
                try? "\(getpid())".write(toFile: "\(p)/pid", atomically: false, encoding: .utf8)
                cSlotDir = strdup(p)
                cSlotPid = strdup("\(p)/pid")
                index = i
                return
            }
        }
        index = 6
    }

    func release() { cleanupFiles() }
}
// MARK: - Views

final class AppGlyph: NSView {
    // Rounded-square icon in the style of macOS app icons: gradient fill, top sheen, white SF Symbol.
    init(symbol: String, top: NSColor, bottom: NSColor, size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.masksToBounds = false
        let r = size * 0.28

        let shadow = CALayer()
        shadow.frame = bounds
        shadow.cornerRadius = r
        shadow.cornerCurve = .continuous
        shadow.backgroundColor = bottom.cgColor
        shadow.shadowColor = bottom.cgColor
        shadow.shadowOpacity = 0.55
        shadow.shadowRadius = 6
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(shadow)

        let fill = CAGradientLayer()
        fill.frame = bounds
        fill.cornerRadius = r
        fill.cornerCurve = .continuous
        fill.masksToBounds = true
        fill.colors = [top.cgColor, bottom.cgColor]
        fill.startPoint = CGPoint(x: 0.2, y: 1)
        fill.endPoint = CGPoint(x: 0.8, y: 0)
        fill.borderWidth = 0.5
        fill.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        layer?.addSublayer(fill)

        let sheen = CAGradientLayer()
        sheen.frame = CGRect(x: 0, y: size * 0.5, width: size, height: size * 0.5)
        sheen.colors = [NSColor.white.withAlphaComponent(0.0).cgColor, NSColor.white.withAlphaComponent(0.28).cgColor]
        fill.addSublayer(sheen)

        let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let iv = NSImageView(image: img)
            iv.contentTintColor = .white
            iv.frame = bounds
            iv.imageScaling = .scaleNone
            iv.wantsLayer = true
            iv.shadow = { let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.25); s.shadowBlurRadius = 2; s.shadowOffset = NSSize(width: 0, height: -0.5); return s }()
            addSubview(iv)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class ToastContent: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    let closeButton = NSButton()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

func label(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) -> NSTextField {
    let f = NSTextField(labelWithString: s)
    if mono {
        f.font = NSFont(name: "JetBrainsMono Nerd Font", size: size)
            ?? NSFont(name: "JetBrains Mono", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
    } else {
        f.font = .systemFont(ofSize: size, weight: weight)
    }
    f.textColor = color
    f.lineBreakMode = .byTruncatingTail
    f.maximumNumberOfLines = 2
    f.cell?.truncatesLastVisibleLine = true
    f.translatesAutoresizingMaskIntoConstraints = false
    return f
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let args = Args()
    let slot = Slot()
    var panel: NSPanel!
    var dismissTimer: Timer?
    var hovering = false
    var closing = false

    let width: CGFloat = 312
    let height: CGFloat = 58
    let margin: CGFloat = 12
    let gap: CGFloat = 8
    let radius: CGFloat = 20

    var accent: NSColor { args.kind == "done" ? Palette.green : args.kind == "permission" ? Palette.peach : Palette.mauve }
    var accentTop: NSColor { args.kind == "done" ? Palette.hex(0x94e2d5) : args.kind == "permission" ? Palette.hex(0xf9e2af) : Palette.hex(0xf5c2e7) }
    var accentBottom: NSColor { args.kind == "done" ? Palette.hex(0x40a02b) : args.kind == "permission" ? Palette.hex(0xe0702f) : Palette.hex(0x8839ef) }
    var symbol: String { args.kind == "done" ? "checkmark" : args.kind == "permission" ? "lock.fill" : "ellipsis.message.fill" }

    func applicationDidFinishLaunching(_ n: Notification) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { exit(0) }
        let vf = screen.visibleFrame
        let y = vf.maxY - margin - height - CGFloat(slot.index) * (height + gap)
        let finalFrame = NSRect(x: vf.maxX - margin - width, y: y, width: width, height: height)

        panel = NSPanel(contentRect: finalFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = wrapInGlass(buildContent())

        panel.setFrame(finalFrame.offsetBy(dx: 24, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
        scheduleDismiss(after: args.duration)
    }

    func wrapInGlass(_ content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            glass.cornerRadius = radius
            glass.tintColor = Palette.crust.withAlphaComponent(0.5)
            glass.contentView = content
            return glass
        }
        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = radius
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.layer?.backgroundColor = Palette.crust.withAlphaComponent(0.45).cgColor
        content.frame = fx.bounds
        content.autoresizingMask = [.width, .height]
        fx.addSubview(content)
        return fx
    }

    func buildContent() -> ToastContent {
        let v = ToastContent(frame: NSRect(x: 0, y: 0, width: width, height: height))
        v.wantsLayer = true
        v.layer?.cornerRadius = radius
        v.layer?.cornerCurve = .continuous
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let icon = AppGlyph(symbol: symbol, top: accentTop, bottom: accentBottom, size: 32)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = label(args.title, size: 12.5, weight: .semibold, color: Palette.text)
        title.maximumNumberOfLines = 1
        let project = label(args.project, size: 10.5, weight: .regular, color: Palette.overlay, mono: true)
        project.maximumNumberOfLines = 1
        let message = label(args.message, size: 11.5, weight: .regular, color: Palette.subtext)
        message.maximumNumberOfLines = 1

        let close = v.closeButton
        close.translatesAutoresizingMaskIntoConstraints = false
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        close.contentTintColor = Palette.subtext
        close.wantsLayer = true
        close.layer?.cornerRadius = 8
        close.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        close.alphaValue = 0
        close.target = self
        close.action = #selector(closeTapped)

        [icon, title, project, message, close].forEach(v.addSubview)

        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        title.setContentHuggingPriority(.required, for: .horizontal)
        project.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 13),
            icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 11),
            title.topAnchor.constraint(equalTo: v.topAnchor, constant: 11),

            project.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
            project.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            project.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -6),

            message.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            message.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            message.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),

            close.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            close.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            close.widthAnchor.constraint(equalToConstant: 16),
            close.heightAnchor.constraint(equalToConstant: 16),
        ])

        v.onHover = { [weak self] inside in
            guard let self else { return }
            self.hovering = inside
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                close.animator().alphaValue = inside ? 1 : 0
            }
            if inside { self.dismissTimer?.invalidate() } else { self.scheduleDismiss(after: 2) }
        }
        v.onClick = { [weak self] in
            self?.focusTerminal()
            self?.dismiss()
        }
        return v
    }

    @objc func closeTapped() { dismiss() }

    func scheduleDismiss(after s: Double) {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
            guard let self, !self.hovering else { return }
            self.dismiss()
        }
    }

    func focusTerminal() {
        guard let id = terminalBundleIDs[args.term],
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
        app.activate()
    }

    func dismiss() {
        guard !closing else { return }
        closing = true
        dismissTimer?.invalidate()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(panel.frame.offsetBy(dx: 20, dy: 0), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.slot.release()
            exit(0)
        })
    }
}

let launchArgs = Args()
// --check-only 1: exit 1 when you are looking at the session, 0 otherwise (used by notify.sh for the island)
if launchArgs.checkOnly { exit(userIsLookingAtSession(launchArgs) ? 1 : 0) }
if userIsLookingAtSession(launchArgs) { exit(0) }
replacePreviousToast(session: launchArgs.session)
signal(SIGTERM) { _ in cleanupFiles(); _exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
// safety net: never linger
DispatchQueue.main.asyncAfter(deadline: .now() + 120) { cleanupFiles(); exit(0) }
app.run()
