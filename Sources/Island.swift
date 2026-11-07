// Claude Island — a Dynamic Island around the MacBook notch for Claude Code sessions.
//
// Runs as a background agent (LaunchAgent dev.claude-island). Reads:
//   ~/.claude/session-state/<sid>.json      session status, written by hooks/session-state.sh
//   ~/.claude/session-state/<sid>.activity  current tool activity, written by hooks/activity.sh
//   ~/.claude/notifier/events/*.json        one-shot events (input / permission / done), written by hooks/notify.sh
// At rest it hides behind the notch. Events expand it into a banner; a click opens an overview of all sessions.
import AppKit
import SwiftUI
import Carbon.HIToolbox
import Combine
import SQLite3

// MARK: - Paths

/// Demo mode (ISLAND_DEMO=1): everything is read from the fixture home in ISLAND_HOME and no personal source
/// (Keychain, Calendar, Reminders, Notification Center, Zed) is touched. Used to record the demo video.
let demoMode = ProcessInfo.processInfo.environment["ISLAND_DEMO"] != nil
let homeDir = ProcessInfo.processInfo.environment["ISLAND_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
let stateDir = homeDir + "/.claude/session-state"
let notifierDir = homeDir + "/.claude/notifier"
let eventsDir = notifierDir + "/events"

let terminalBundleIDs: [String: String] = [
    "ghostty": "com.mitchellh.ghostty",
    "zed": "dev.zed.Zed",
    "Apple_Terminal": "com.apple.Terminal",
    "iTerm.app": "com.googlecode.iterm2",
    "vscode": "com.microsoft.VSCode",
    "WarpTerminal": "dev.warp.Warp-Stable",
]

func focusTerminal(_ term: String) {
    let id = terminalBundleIDs[term] ?? "dev.zed.Zed"
    NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate()
}

// MARK: - Focus the exact Zed window/project of a session

struct ZedWorkspace { let id: Int64; let roots: [String]; let terminals: [String]; let ts: String }

/// Open Zed workspaces from Zed's own state DB (read only): roots plus the cwd of each terminal tab.
func zedWorkspaces() -> [ZedWorkspace] {
    let path = NSHomeDirectory() + "/Library/Application Support/Zed/db/0-stable/db.sqlite"
    var db: OpaquePointer?
    guard !demoMode, sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 200)
    func rows(_ sql: String, _ each: (OpaquePointer) -> Void) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW { each(st) }
    }
    func text(_ st: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
    }
    var terms: [Int64: [String]] = [:]
    rows("select workspace_id, working_directory_path from terminals") { st in
        terms[sqlite3_column_int64(st, 0), default: []].append(text(st, 1))
    }
    var out: [ZedWorkspace] = []
    rows("select workspace_id, paths, timestamp from workspaces where window_id is not null and paths != '' order by timestamp desc") { st in
        let id = sqlite3_column_int64(st, 0)
        let roots = text(st, 1).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if !roots.isEmpty { out.append(ZedWorkspace(id: id, roots: roots, terminals: terms[id] ?? [], ts: text(st, 2))) }
    }
    // only the workspaces saved in the latest session (open ones are re-saved together)
    guard let latest = out.first?.ts, let top = zedDate(latest) else { return out }
    return out.filter { (zedDate($0.ts).map { top.timeIntervalSince($0) < 86400 }) ?? false }
}

private func zedDate(_ s: String) -> Date? {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.date(from: s)
}

/// The workspace a session's terminal lives in: a terminal tab with the same cwd wins,
/// then the workspace whose root contains the cwd (the closest root).
func zedWorkspace(for cwd: String) -> ZedWorkspace? {
    let c = (cwd as NSString).standardizingPath
    let ws = zedWorkspaces()
    if let w = ws.first(where: { $0.terminals.contains(c) }) { return w }
    func depth(_ w: ZedWorkspace) -> Int {
        w.roots.filter { c == $0 || c.hasPrefix($0 + "/") }.map(\.count).max() ?? -1
    }
    return ws.filter { depth($0) >= 0 }.max { depth($0) < depth($1) }
}

/// Bring the session's own window forward (switching Space if needed); falls back to the app.
/// The window then lights up briefly in the session's color, so the eye lands on it.
func focusSession(term: String, cwd: String, tty: String = "", glow: Color = Color(hex: 0xcba6f7)) {
    let isZed = term.isEmpty || term == "zed"
    let cli = "/Applications/Zed.app/Contents/MacOS/cli"
    guard isZed, !cwd.isEmpty, FileManager.default.isExecutableFile(atPath: cli),
          let w = zedWorkspace(for: cwd) else {
        focusTerminal(term)
        WindowGlow.flash(owner: isZed ? "Zed" : nil, roots: [], color: glow)
        return
    }
    // passing exactly the workspace's roots makes Zed reuse that window instead of opening the folder anew
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = w.roots
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { focusTerminal(term) }
    // then the exact terminal tab: panel, pane and tab via the hidden shortcuts in the Zed keymap
    if ZedKeys.ready(), let t = zedTabTarget(workspace: w.id, cwd: cwd, tty: tty) {
        ZedKeys.send(ZedKeys.sequence(for: t)) { WindowGlow.flash(owner: "Zed", roots: w.roots, color: glow) }
    } else {
        WindowGlow.flash(owner: "Zed", roots: w.roots, color: glow)
    }
}

// MARK: - Window glow (a light ring around the window you just jumped to)

enum WindowGlow {
    private static var panel: NSPanel?

    /// On-screen frame (Cocoa coordinates) of the app's window showing one of `roots`, else its front window.
    static func frame(owner: String?, roots: [String]) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let names = Set(roots.map { ($0 as NSString).lastPathComponent })
        var best: [String: Any]?
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            let app = w[kCGWindowOwnerName as String] as? String ?? ""
            if let owner, app != owner { continue }
            if owner == nil, app == "Claude Island" { continue }
            let title = w[kCGWindowName as String] as? String ?? ""
            let worktrees = (title.components(separatedBy: " — ").first ?? "").components(separatedBy: ", ")
            if !names.isEmpty, worktrees.contains(where: names.contains) { best = w; break }
            // titles need Screen Recording access; without them the front window of the app is the one we raised
            if best == nil, owner != nil || !title.isEmpty { best = w }
        }
        guard let b = best?[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let wd = b["Width"], let h = b["Height"], wd > 80, h > 80 else { return nil }
        let top = NSScreen.screens.first?.frame.maxY ?? 0   // CG origin is the top-left of the primary screen
        return NSRect(x: x, y: top - y - h, width: wd, height: h)
    }

    static func flash(owner: String?, roots: [String], color: Color, attempt: Int = 0) {
        // wait for the window to come forward (and a Space switch to settle)
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.32 : 0.25)) {
            guard let f = frame(owner: owner, roots: roots) else {
                if attempt < 3 { flash(owner: owner, roots: roots, color: color, attempt: attempt + 1) }
                return
            }
            show(f, color: color)
        }
    }

    private static func show(_ window: NSRect, color: Color) {
        panel?.orderOut(nil)
        let pad: CGFloat = 40
        let rect = window.insetBy(dx: -pad, dy: -pad)
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        let view = GlowRing(color: color, pad: pad) { p.orderOut(nil); if panel === p { panel = nil } }
        p.contentView = NSHostingView(rootView: view.frame(width: rect.width, height: rect.height))
        p.orderFrontRegardless()
        panel = p
    }
}

/// Soft light that blooms around the window edge and fades, like the island's own glow.
struct GlowRing: View {
    let color: Color
    let pad: CGFloat
    let done: () -> Void
    @State private var on = false
    @State private var out = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            shape.stroke(color, lineWidth: 14).blur(radius: 22).opacity(0.75)
            shape.stroke(color, lineWidth: 4).blur(radius: 6).opacity(0.6)
            shape.stroke(LinearGradient(colors: [color, Color(hex: 0x89b4fa), color], startPoint: .topLeading, endPoint: .bottomTrailing),
                         lineWidth: 3)
                .blur(radius: 1.2)
            shape.stroke(.white.opacity(0.5), lineWidth: 0.8)
        }
        .padding(pad)
        .scaleEffect(on ? 1 : 1.025)
        .opacity(out ? 0 : on ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { on = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
                withAnimation(.easeInOut(duration: 0.8)) { out = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { done() }
        }
    }
}

// MARK: - Palette (Catppuccin Mocha)

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

enum Pal {
    static let text = Color(hex: 0xcdd6f4)
    static let subtext = Color(hex: 0xa6adc8)
    static let overlay = Color(hex: 0x7f849c)
    static let surface = Color(hex: 0x313244)
}

enum Kind: String {
    case input, permission, done, working, idle, blocked  // blocked: a paused queue waits for you
    case meeting, chat, mail                                  // not sessions: calendar and Google Chat banners

    var symbol: String {
        switch self {
        case .input: return "ellipsis.message.fill"
        case .permission: return "lock.fill"
        case .done, .idle: return "checkmark"
        case .working: return "sparkle"
        case .blocked: return "hand.raised.fill"
        case .meeting: return "calendar"
        case .chat: return "bubble.left.and.text.bubble.right.fill"
        case .mail: return "envelope.fill"
        }
    }
    var top: Color {
        switch self {
        case .input: return Color(hex: 0xf5c2e7)
        case .permission: return Color(hex: 0xf9e2af)
        case .done, .idle: return Color(hex: 0x94e2d5)
        case .working: return Color(hex: 0x89dceb)
        case .blocked: return Color(hex: 0xf2cdcd)
        case .meeting: return Color(hex: 0x89dceb)
        case .chat: return Color(hex: 0xa6e3a1)
        case .mail: return Color(hex: 0xb4befe)
        }
    }
    var bottom: Color {
        switch self {
        case .input: return Color(hex: 0x8839ef)
        case .permission: return Color(hex: 0xe0702f)
        case .done, .idle: return Color(hex: 0x40a02b)
        case .working: return Color(hex: 0x1e66f5)
        case .blocked: return Color(hex: 0xdd7878)
        case .meeting: return Color(hex: 0x209fb5)
        case .chat: return Color(hex: 0x179299)
        case .mail: return Color(hex: 0x7287fd)
        }
    }
    var accent: Color {
        switch self {
        case .input: return Color(hex: 0xcba6f7)
        case .permission: return Color(hex: 0xfab387)
        case .done, .idle: return Color(hex: 0xa6e3a1)
        case .working: return Color(hex: 0x89b4fa)
        case .blocked: return Color(hex: 0xf2a7b5)
        case .meeting: return Color(hex: 0x74c7ec)
        case .chat: return Color(hex: 0x94e2d5)
        case .mail: return Color(hex: 0xb4befe)
        }
    }
    var needsAttention: Bool { self == .input || self == .permission || self == .blocked }
}

// MARK: - Data

struct Session: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
    let reason: String
    let since: Date
    let term: String
    let tty: String
    let cwd: String
    let account: String
    let activity: String?
    var queueHold: String = ""   // why this session's queue paused and waits for you

    var kind: Kind {
        if status == "working" { return .working }
        if !queueHold.isEmpty { return .blocked }
        if reason.localizedCaseInsensitiveContains("permission") { return .permission }
        // the 60s idle reminder is just "your turn", not a real question
        if !reason.isEmpty && !reason.localizedCaseInsensitiveContains("waiting for your input") { return .input }
        return .idle
    }

    var subtitle: String {
        switch kind {
        case .working: return activity ?? "Thinking…"
        case .permission:
            if let r = reason.range(of: "permission to use ") { return "Needs permission · " + reason[r.upperBound...] }
            return "Needs permission"
        case .input: return "Waiting for your reply"
        case .blocked:
            let r = queueHold.trimmingCharacters(in: .whitespaces)
            return r.prefix(1).uppercased() + r.dropFirst()
        case .idle, .done, .meeting, .chat, .mail: return "Your turn"
        }
    }

    var sortRank: Int {
        switch kind {
        case .permission, .blocked: return 0
        case .input: return 1
        case .working: return 2
        default: return 3
        }
    }
}

struct IslandEvent: Equatable {
    let kind: Kind
    let title: String
    let message: String
    let project: String
    let session: String
    let term: String
    var action: String = ""
    let at: Date
    var url: URL? = nil          // meeting call link / app to open on click
}

func elapsed(since d: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

// MARK: - Screen geometry

enum Display: Hashable { case rest, compact, banner, overview }

struct ScreenInfo: Equatable {
    let id: CGDirectDisplayID
    let frame: NSRect
    let hasNotch: Bool      // always true: screens without a hardware notch get a drawn one
    let isVirtual: Bool     // the notch is drawn by us (external monitor)
    let isBuiltin: Bool
    let notchW: CGFloat
    let notchH: CGFloat

    init(_ s: NSScreen) {
        id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        frame = s.frame
        isBuiltin = CGDisplayIsBuiltin(id) != 0
        hasNotch = true
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            isVirtual = false
            notchW = s.frame.width - l.width - r.width
            notchH = s.safeAreaInsets.top
        } else {
            isVirtual = true
            notchW = 150
            notchH = 28
        }
    }

    /// Height of the band at the top that the notch (or menu bar) occupies; content goes below it.
    /// Band at the top hidden by a hardware notch; content goes below it. A drawn notch hides nothing,
    /// so on the external monitor the banner lives inside the notch itself.
    var topBand: CGFloat { isVirtual ? 0 : notchH }

    func flare(_ d: Display) -> CGFloat { d == .rest ? (isVirtual ? 7 : 5) : (d == .compact ? 7 : 10) }

    func bottomRadius(_ d: Display) -> CGFloat {
        switch d {
        case .rest: return isVirtual ? 12 : 9
        case .compact: return hasNotch ? 11 : 14
        case .banner: return isVirtual ? 15 : 18
        case .overview: return 24
        }
    }

    /// Body size of the island (without the top flares).
    func size(_ d: Display, overviewH: CGFloat, hover: Bool, ambientW: CGFloat = 0, banner: CGSize? = nil) -> CGSize {
        let h: CGFloat = hover ? 1 : 0
        switch d {
        case .rest:
            if isVirtual { return CGSize(width: max(notchW, ambientW) + 12 * h, height: notchH + 3 * h) }
            return CGSize(width: notchW - 8 + 16 * h, height: notchH - 2 + 5 * h)
        case .compact:
            if isVirtual { return CGSize(width: max(notchW + 56, ambientW) + 10 * h, height: notchH + 2 * h) }
            return hasNotch ? CGSize(width: notchW + 56 + 10 * h, height: notchH + 2 * h)
                            : CGSize(width: 170 + 10 * h, height: 26 + 2 * h)
        case .banner:
            if let banner { return banner }
            if isVirtual { return CGSize(width: notchW + 116, height: notchH + 10) }
            return CGSize(width: notchW + 84, height: topBand + 38)
        case .overview:
            return CGSize(width: OV.width, height: overviewH)
        }
    }

    func outerSize(_ d: Display, overviewH: CGFloat, hover: Bool, ambientW: CGFloat = 0, banner: CGSize? = nil) -> CGSize {
        let s = size(d, overviewH: overviewH, hover: hover, ambientW: ambientW, banner: banner)
        return CGSize(width: s.width + 2 * flare(d), height: s.height)
    }
}

// MARK: - Model

final class IslandModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var banner: IslandEvent?
    @Published var mode: Display = .rest          // .rest / .banner / .overview on `activeScreen`
    @Published var activeScreen: CGDirectDisplayID?
    @Published var hoverScreen: CGDirectDisplayID?
    @Published var tab: OverviewTab = .sessions
    @Published var expanded: String?              // session whose queue editor is open
    @Published var sending: String?               // reminder being handed to a session
    @Published var focusRequest = 0               // bump to focus the task field
    var lastBanner: IslandEvent?                  // still drawn while a closing banner leaves
    @Published var peek = false                   // Option held: the banner shows its whole message and stays
    var focusTasksOnAppear = false

    let queues = QueueStore()
    let usage = UsageStore()
    let reminders = RemindersStore()
    let calendar = CalendarStore()

    private var bannerTimer: Timer?
    private var liveTTYs: Set<String> = []
    private var lastLivenessCheck = Date.distantPast

    var attention: [Session] { sessions.filter { $0.kind.needsAttention } }

    func display(for id: CGDirectDisplayID) -> Display {
        if activeScreen == id, mode == .banner || mode == .overview { return mode }
        return attention.isEmpty ? .rest : .compact
    }

    // banner sizing: notes from people (chat, meetings) get a wide banner with two lines;
    // holding Option opens any banner to its whole message

    static let bannerFont = NSFont.systemFont(ofSize: 10.5)
    static let bannerLine: CGFloat = 14.5

    private func bannerWidth(_ s: ScreenInfo) -> CGFloat? {
        guard let b = banner ?? lastBanner else { return nil }
        if peek || b.kind == .chat || b.kind == .mail || b.kind == .meeting { return 460 }
        return nil
    }

    /// Lines the whole message needs at the banner's width.
    private func messageLines(_ s: ScreenInfo, width: CGFloat) -> Int {
        guard let b = banner ?? lastBanner, !b.message.isEmpty else { return 1 }
        let textW = width - 2 * s.flare(.banner) - 2 * (s.isVirtual ? 9 : 11) - 26 - 8 + 6
        let r = (b.message as NSString).boundingRect(with: CGSize(width: textW, height: 2000), options: [.usesLineFragmentOrigin],
                                                    attributes: [.font: Self.bannerFont])
        return max(1, Int((r.height / (Self.bannerFont.ascender - Self.bannerFont.descender + Self.bannerFont.leading)).rounded(.up)))
    }

    func bannerLines(_ s: ScreenInfo) -> Int {
        guard let w = bannerWidth(s) else { return 1 }
        let need = messageLines(s, width: w)
        return peek ? min(need, 16) : min(need, 2)
    }

    func bannerTruncated(_ s: ScreenInfo) -> Bool {
        guard !peek, banner != nil else { return false }
        let w = bannerWidth(s) ?? (s.size(.banner, overviewH: 0, hover: false).width + 2 * s.flare(.banner))
        return messageLines(s, width: w) > bannerLines(s)
    }

    func bannerSize(_ s: ScreenInfo) -> CGSize? {
        guard let w = bannerWidth(s) else { return nil }
        let base = s.size(.banner, overviewH: 0, hover: false)
        let extra = CGFloat(bannerLines(s) - 1) * Self.bannerLine
        return CGSize(width: w - 2 * s.flare(.banner), height: base.height + extra + (bannerLines(s) > 1 ? 6 : 0))
    }

    // events

    func show(_ e: IslandEvent, on screen: CGDirectDisplayID?) {
        if mode == .overview { return }  // overview already shows everything
        banner = e
        lastBanner = e
        activeScreen = screen
        mode = .banner
        scheduleCollapse(after: e.action == "hold" ? 3.2 : e.kind == .blocked || e.kind == .meeting ? 9 : e.kind == .done ? 4 : 6)
    }

    func scheduleCollapse(after s: TimeInterval) {
        bannerTimer?.invalidate()
        bannerTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.mode == .banner, self.hoverScreen == self.activeScreen { return }
            self.collapse()
        }
    }

    func pauseCollapse() { bannerTimer?.invalidate() }

    func openOverview(on screen: CGDirectDisplayID) {
        bannerTimer?.invalidate()
        activeScreen = screen
        mode = .overview
    }

    func collapse() {
        bannerTimer?.invalidate()
        // inside a transaction, so the leaving content can play its way out
        withAnimation(.easeOut(duration: 0.22)) {
            mode = .rest
            banner = nil
            expanded = nil
            sending = nil
        }
    }

    // polling

    func refreshSessions() {
        let fm = FileManager.default
        if Date().timeIntervalSince(lastLivenessCheck) > 3 { refreshLiveness() }
        guard let files = try? fm.contentsOfDirectory(atPath: stateDir) else { return }
        var out: [Session] = []
        for f in files where f.hasSuffix(".json") {
            let path = stateDir + "/" + f
            guard let data = fm.contents(atPath: path),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let tty = j["tty"] as? String ?? ""
            if !tty.isEmpty, !liveTTYs.isEmpty, !liveTTYs.contains(tty) { continue }  // session process is gone
            let sid = j["session_id"] as? String ?? f
            var activity: String?
            if let a = try? String(contentsOfFile: stateDir + "/" + sid + ".activity", encoding: .utf8) {
                let t = a.trimmingCharacters(in: .whitespacesAndNewlines)
                activity = t.isEmpty ? nil : t
            }
            out.append(Session(
                id: sid,
                name: j["name"] as? String ?? "claude",
                status: j["status"] as? String ?? "waiting",
                reason: j["reason"] as? String ?? "",
                since: Date(timeIntervalSince1970: (j["ts"] as? Double) ?? Date().timeIntervalSince1970),
                term: j["term"] as? String ?? "",
                tty: tty,
                cwd: j["cwd"] as? String ?? "",
                account: j["account"] as? String ?? "",
                activity: activity,
                queueHold: queueHold(sid, status: j["status"] as? String ?? "waiting")))
        }
        out.sort { ($0.sortRank, $1.since) < ($1.sortRank, $0.since) }
        if out != sessions { sessions = out }

        // you answered the session whose banner is showing → the banner is stale
        if mode == .banner, let b = banner, let s = out.first(where: { $0.id == b.session }),
           s.status == "working", s.since > b.at.addingTimeInterval(-1) {
            collapse()
        }
    }

    /// Why this session's queue is waiting on you (empty when it is not).
    /// A queued task that is "running" in a session that has stopped can only move on through you,
    /// whatever the pause flag says.
    private func queueHold(_ sid: String, status: String) -> String {
        guard let q = queues.queues[sid], status != "working" else { return "" }
        if q.isPaused, ["blocked", "needs", "limit"].contains(q.pauseKind ?? "") {
            return (q.pauseReason ?? "").isEmpty ? "Waiting for you" : q.pauseReason!
        }
        if let r = q.running {
            if let n = r.note, !n.isEmpty { return n }
            return "Waiting for your reply"
        }
        return ""
    }

    private func refreshLiveness() {
        lastLivenessCheck = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "tty=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var ttys = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let comm = parts[1].trimmingCharacters(in: .whitespaces)
            if comm == "claude" || comm.hasSuffix("/claude") { ttys.insert(String(parts[0])) }
        }
        liveTTYs = ttys
    }

    func drainEvents(screenForEvent: () -> CGDirectDisplayID?) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: eventsDir), !files.isEmpty else { return }
        var latest: IslandEvent?
        var wantsOverview = false
        for f in files.sorted() where f.hasSuffix(".json") {
            let path = eventsDir + "/" + f
            defer { try? fm.removeItem(atPath: path) }
            guard let data = fm.contents(atPath: path),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if j["kind"] as? String == "overview" {
                wantsOverview = true
                if let t = j["tab"] as? String, let tab = OverviewTab(rawValue: t) { self.tab = tab }
                if let e = j["expand"] as? String { expanded = e.isEmpty ? nil : e }
                continue
            }
            if j["kind"] as? String == "collapse" { collapse(); continue }
            if j["kind"] as? String == "focus", let sid = j["session"] as? String,
               let s = sessions.first(where: { $0.id == sid }) {
                focusSession(term: s.term, cwd: s.cwd, tty: s.tty, glow: s.kind.accent)
                continue
            }
            latest = IslandEvent(
                kind: Kind(rawValue: j["kind"] as? String ?? "") ?? .input,
                title: j["title"] as? String ?? "Claude",
                message: j["message"] as? String ?? "",
                project: j["project"] as? String ?? "",
                session: j["session"] as? String ?? "",
                term: j["term"] as? String ?? "",
                action: j["action"] as? String ?? "",
                at: Date())
        }
        if let e = latest { show(e, on: screenForEvent()) }
        if wantsOverview, let id = screenForEvent() { openOverview(on: id) }
    }
}

// MARK: - Shapes and small views

/// Hangs from the top edge: concave flares at the top corners, rounded bottom corners.
struct IslandShape: Shape {
    var flare: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, bottom) }
        set { flare = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = flare
        let b = min(bottom, (r.height) / 2, (r.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// App-icon style glyph: gradient squircle, top sheen, white SF Symbol.
struct Glyph: View {
    let kind: Kind
    var size: CGFloat = 32

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [kind.top, kind.bottom], startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0)], startPoint: .top, endPoint: .center))
            shape.strokeBorder(.white.opacity(0.28), lineWidth: 0.5)
            symbol
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        }
        .frame(width: size, height: size)
        .shadow(color: kind.bottom.opacity(0.55), radius: size * 0.2, y: 1)
    }

    @ViewBuilder var symbol: some View {
        if kind == .working {
            Image(systemName: kind.symbol).symbolEffect(.pulse, options: .repeating)
        } else {
            Image(systemName: kind.symbol)
        }
    }
}

struct PulseDot: View {
    let color: Color
    @State private var on = false
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: 12, height: 12).scaleEffect(on ? 1.15 : 0.6).opacity(on ? 0 : 1)
            Circle().fill(color).frame(width: 6, height: 6).shadow(color: color, radius: 4)
        }
        .frame(width: 14, height: 14)
        .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } }
    }
}

/// Small bouncy entrance for icons.
struct PopIn: ViewModifier {
    let delay: Double
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.4)
            .rotationEffect(.degrees(shown ? 0 : -12))
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.55).delay(delay)) { shown = true } }
    }
}

/// "Hold" capsule on the Up-next banner with a ring that runs out when the task starts.
struct HoldButton: View {
    let color: Color
    @State private var left: CGFloat = 1
    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(color.opacity(0.25), lineWidth: 1.6)
                Circle().trim(from: 0, to: left).stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 10, height: 10)
            Text("Hold").font(.system(size: 10, weight: .semibold)).foregroundStyle(Pal.text)
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(.white.opacity(0.1)))
        .onAppear { withAnimation(.linear(duration: 3)) { left = 0 } }
    }
}

struct BlurFade: ViewModifier {
    let radius: CGFloat
    let opacity: Double
    let scale: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity).scaleEffect(scale, anchor: .top)
    }
}

extension AnyTransition {
    /// Opening: the shape leads and the content blooms in once there is room for it.
    /// Closing: the old content leaves at once and the smaller content settles in as the shape arrives.
    static func islandContent(opening: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurFade(radius: opening ? 10 : 5, opacity: 0, scale: opening ? 0.9 : 0.97),
                                 identity: BlurFade(radius: 0, opacity: 1, scale: 1))
                .animation(opening ? .spring(response: 0.46, dampingFraction: 0.86).delay(0.11)
                                   : .easeOut(duration: 0.3).delay(0.13)),
            // the old content shrinks into the top with the shape instead of blinking out
            removal: .modifier(active: BlurFade(radius: 6, opacity: 0, scale: 0.9),
                               identity: BlurFade(radius: 0, opacity: 1, scale: 1))
                .animation(.easeOut(duration: 0.2)))
    }
}

let monoFont: Font = {
    if NSFont(name: "JetBrainsMono Nerd Font", size: 11) != nil { return .custom("JetBrainsMono Nerd Font", size: 10.5) }
    return .system(size: 10.5, design: .monospaced)
}()

// MARK: - Content views

struct CompactContent: View {
    let screen: ScreenInfo
    let attention: [Session]

    var body: some View {
        let first = attention.first
        HStack(spacing: 8) {
            if let s = first { Glyph(kind: s.kind, size: 16).modifier(PopIn(delay: 0.1)) }
            if screen.hasNotch && !screen.isVirtual {
                Spacer(minLength: screen.notchW)
            } else if let s = first {
                Text(attention.count > 1 ? "\(attention.count) sessions waiting" : s.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Pal.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                if attention.count > 1 {
                    Text("\(attention.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(first?.kind.accent ?? .white)
                        .contentTransition(.numericText())
                }
                PulseDot(color: first?.kind.accent ?? .white)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
    }
}

struct BannerContent: View {
    let screen: ScreenInfo
    let event: IslandEvent
    var lines = 1
    var truncated = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: screen.topBand)
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(event.kind.accent.opacity(0.35)).frame(width: 26, height: 26).blur(radius: 9)
                    Glyph(kind: event.kind, size: screen.isVirtual ? 20 : 22)
                }
                .modifier(PopIn(delay: 0.12))
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(event.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Pal.text)
                            .lineLimit(1)
                            .fixedSize()
                        Text(event.project)
                            .font(monoFont)
                            .foregroundStyle(event.kind.accent.opacity(0.9))
                            .lineLimit(1)
                        if truncated {
                            Spacer(minLength: 4)
                            // a quiet hint, set on the title's baseline and kept clear of the rounded corner
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text("⌥").font(.system(size: 10, weight: .semibold))
                                Text("to read all").font(.system(size: 9.5))
                            }
                            .foregroundStyle(Pal.overlay.opacity(0.85))
                            .padding(.trailing, 8)
                            .fixedSize()
                            .transition(.opacity)
                        }
                    }
                    Text(event.message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(lines > 1 ? Pal.text.opacity(0.88) : Pal.subtext)
                        .lineSpacing(1.5)
                        .lineLimit(lines)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if event.action == "hold" {
                    HoldButton(color: event.kind.accent).modifier(PopIn(delay: 0.2))
                }
            }
            .padding(.horizontal, screen.isVirtual ? 9 : 11)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Island view

struct Geometry: Equatable {
    var w: CGFloat
    var h: CGFloat
    var flare: CGFloat
    var bottom: CGFloat
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var queues: QueueStore
    @ObservedObject var usage: UsageStore
    @ObservedObject var reminders: RemindersStore
    @ObservedObject var calendar: CalendarStore
    let screen: ScreenInfo
    @State private var geo: Geometry?   // animated geometry of the black shape
    @State private var glow: Double = 0
    @State private var lastGlow: Kind?
    @State private var shownD: Display?    // the state drawn last; becomes the leaving layer when it changes
    @State private var leaving: Display?
    @State private var leaveFade: Double = 1  // 0…1 intensity of the light behind the island

    /// Colors of the glow for what the island currently shows.
    func glowKind(_ d: Display) -> Kind? {
        switch d {
        case .rest: return nil
        case .compact: return model.attention.first?.kind
        case .banner: return model.banner?.kind
        case .overview: return model.attention.first?.kind ?? .working
        }
    }

    func target(_ d: Display, hover: Bool) -> Geometry {
        let s = screen.outerSize(d, overviewH: model.overviewHeight(screen), hover: hover,
                                 ambientW: screen.isVirtual ? model.ambientWidth(usage, calendar, waiting: d == .compact) : 0,
                                 banner: model.bannerSize(screen))
        return Geometry(w: s.width, h: s.height, flare: screen.flare(d), bottom: screen.bottomRadius(d))
    }

    var body: some View {
        let d = model.display(for: screen.id)
        let hover = model.hoverScreen == screen.id && (d == .rest || d == .compact)
        let t = target(d, hover: hover)
        let g = geo ?? t
        let shape = IslandShape(flare: g.flare, bottom: g.bottom)
        let visible = screen.hasNotch || d != .rest || g.h > 1
        let expanded = d == .banner || d == .overview

        let gk: Kind? = glowKind(d) ?? lastGlow   // the light fades out in the color it had
        ZStack(alignment: .top) {
            // light leaking out from behind the island: a blurred, slightly larger copy of its shape
            if let gk {
                ZStack {
                    shape.fill(LinearGradient(colors: [gk.top, gk.bottom, gk.accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.w + 16, height: g.h + 10)
                        .blur(radius: 22)
                    shape.fill(gk.accent)
                        .frame(width: g.w * 0.8, height: g.h + 4)
                        .blur(radius: 10)
                        .opacity(0.5)
                }
                .opacity(glow)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

        ZStack(alignment: .top) {
            ZStack {
                shape.fill(.black)
                // glass rim: a light edge that fades in towards the bottom
                shape.stroke(LinearGradient(colors: [.white.opacity(0), .white.opacity(expanded ? 0.16 : 0.08)],
                                            startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .opacity(d == .rest ? 0 : 1)
            }
            .frame(width: g.w, height: g.h)

            // content is laid out at its final size and revealed by the growing shape (no reflow while animating).
            // The state being left stays as its own layer and fades out while the shape moves.
            ZStack(alignment: .top) {
                ForEach(layers(d), id: \.self) { x in
                    let lt = target(x, hover: hover)
                    let current = x == d
                    content(x)
                        .padding(.horizontal, lt.flare)
                        .frame(width: lt.w, height: lt.h)
                        .modifier(BlurFade(radius: current ? 0 : 6 * (1 - leaveFade), opacity: current ? 1 : leaveFade,
                                           scale: current ? 1 : 0.92 + 0.08 * leaveFade))
                        .allowsHitTesting(current)
                        .transition(.islandContent(opening: t.w * t.h >= g.w * g.h))
                }
            }
            .frame(width: max(g.w, t.w), alignment: .top)
        }
        .frame(width: max(g.w, t.w), height: max(g.h, t.h), alignment: .top)
        .mask(alignment: .top) { shape.frame(width: g.w, height: g.h) }
        .shadow(color: .black.opacity(expanded ? 0.4 : 0), radius: 14, y: 6)
        .animation(.easeOut(duration: 0.3), value: expanded)
        .contentShape(Rectangle().size(width: g.w, height: g.h).offset(x: (max(g.w, t.w) - g.w) / 2))
        .onTapGesture { tapped(d) }
        }
        .opacity(visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { geo = t; shownD = d; flash(for: d) }
        .onChange(of: t) { old, new in morph(from: old, to: new) }
        .onChange(of: d) { old, new in
            flash(for: new)
            leave(old)
            shownD = new
        }
        .onChange(of: model.banner) { _, _ in if d == .banner { flash(for: .banner) } }
    }

    /// Current state, plus the one being left while it fades out.
    func layers(_ d: Display) -> [Display] {
        var out = [d]
        for x in [shownD, leaving].compactMap({ $0 }) where !out.contains(x) { out.append(x) }
        return out
    }

    func leave(_ old: Display) {
        leaving = old
        leaveFade = 1
        withAnimation(.easeOut(duration: 0.2)) { leaveFade = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if leaving == old { leaving = nil; leaveFade = 1 }
        }
    }

    @ViewBuilder func content(_ x: Display) -> some View {
        switch x {
        case .rest:
            if screen.isVirtual {
                AmbientContent(sessions: model.ambientSessions, limit: model.ambientLimit(usage), calendar: calendar)
            } else { Color.clear }
        case .compact:
            if screen.isVirtual {
                AmbientContent(sessions: model.ambientSessions, attention: model.attention,
                               limit: model.ambientLimit(usage), calendar: calendar)
            } else { CompactContent(screen: screen, attention: model.attention) }
        case .banner:
            if let e = model.banner ?? model.lastBanner {
                BannerContent(screen: screen, event: e, lines: model.bannerLines(screen), truncated: model.bannerTruncated(screen))
            }
        case .overview:
            OverviewContent(screen: screen, model: model, queues: queues, usage: usage, reminders: reminders)
        }
    }

    /// Bloom the glow as the island opens, then settle into a soft afterglow.
    func flash(for d: Display) {
        if let k = glowKind(d) { lastGlow = k }
        let rest: Double
        switch d {
        case .rest: rest = 0
        case .compact: rest = 0.35
        case .banner: rest = 0.55
        case .overview: rest = 0.3
        }
        if rest == 0 {
            withAnimation(.easeOut(duration: 0.55)) { glow = 0 }
            return
        }
        withAnimation(.easeOut(duration: 0.28).delay(0.04)) { glow = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeInOut(duration: 1.4)) { glow = rest }
        }
    }

    /// Dynamic Island style morph: growing leads with width then height (with a little overshoot);
    /// shrinking lets the content fade first, then pulls in height and finally width.
    func morph(from old: Geometry, to new: Geometry) {
        let growing = new.w * new.h >= old.w * old.h
        // small changes in the same state (a dot, a meeting, Option) just glide
        let small = abs(new.w - old.w) < 80 && abs(new.h - old.h) < 40
        if small {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { geo = new }
        } else if growing {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.76)) {
                geo?.w = new.w
                geo?.flare = new.flare
            }
            withAnimation(.spring(response: 0.48, dampingFraction: 0.78).delay(0.04)) {
                geo?.h = new.h
                geo?.bottom = new.bottom
            }
        } else {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.9).delay(0.05)) {
                geo?.h = new.h
                geo?.bottom = new.bottom
            }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.9).delay(0.11)) {
                geo?.w = new.w
                geo?.flare = new.flare
            }
        }
    }

    func tapped(_ d: Display) {
        switch d {
        case .rest, .compact: model.openOverview(on: screen.id)
        case .banner:
            if let b = model.banner {
                if b.action == "hold" {
                    model.queues.hold(b.session)   // stop the queued task from starting
                } else if b.kind == .meeting || b.kind == .chat || b.kind == .mail {
                    if let u = b.url { NSWorkspace.shared.open(u) }
                } else {
                    let s = model.sessions.first { $0.id == b.session }
                    focusSession(term: b.term, cwd: s?.cwd ?? "", tty: s?.tty ?? "", glow: b.kind.accent)
                }
            }
            model.collapse()
        case .overview: break
        }
    }
}

// MARK: - Windows

/// Takes keyboard focus (for the task fields) only while the overview is open, without activating the app.
final class IslandPanel: NSPanel {
    var canKey: () -> Bool = { false }
    override var canBecomeKey: Bool { canKey() }
    override var canBecomeMain: Bool { false }
}

final class HostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class IslandWindowController {
    static let canvas = CGSize(width: 720, height: 640)
    let screen: ScreenInfo
    let panel: NSPanel

    init(screen: ScreenInfo, model: IslandModel) {
        self.screen = screen
        let c = Self.canvas
        let rect = NSRect(x: screen.frame.midX - c.width / 2, y: screen.frame.maxY - c.height, width: c.width, height: c.height)
        let p = IslandPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.canKey = { [weak model] in model?.mode == .overview }
        panel = p
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = HostingView(rootView: IslandView(model: model, queues: model.queues, usage: model.usage,
                                                    reminders: model.reminders, calendar: model.calendar, screen: screen))
        host.frame = NSRect(origin: .zero, size: c)
        panel.contentView = host
        panel.setFrame(rect, display: false)
        panel.orderFrontRegardless()
    }

    func islandRect(_ model: IslandModel) -> NSRect {
        let d = model.display(for: screen.id)
        let aw = screen.isVirtual ? model.ambientWidth(model.usage, model.calendar, waiting: d == .compact) : 0
        var s = screen.outerSize(d, overviewH: model.overviewHeight(screen), hover: false, ambientW: aw, banner: model.bannerSize(screen))
        if d == .rest {  // whole notch is the hot zone
            s = CGSize(width: screen.isVirtual ? max(screen.notchW, aw) : screen.notchW, height: screen.notchH)
        }
        return NSRect(x: screen.frame.midX - s.width / 2, y: screen.frame.maxY - s.height, width: s.width, height: s.height)
    }
}

// MARK: - Hotkeys (Carbon: global, needs no Accessibility permission)

final class HotKeys {
    static let toggleID: UInt32 = 1
    static let escapeID: UInt32 = 2
    static let tasksID: UInt32 = 3
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: ((UInt32) -> Void)?

    func install(_ h: @escaping (UInt32) -> Void) {
        handler = h
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<HotKeys>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.handler?(hk.id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func register(id: UInt32, key: UInt32, mods: UInt32) {
        guard refs[id] == nil else { return }
        var ref: EventHotKeyRef?
        let hid = EventHotKeyID(signature: OSType(0x434C_4953), id: id)  // 'CLIS'
        if RegisterEventHotKey(key, mods, hid, GetApplicationEventTarget(), 0, &ref) == noErr, let ref { refs[id] = ref }
    }

    func unregister(id: UInt32) {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel()
    var controllers: [IslandWindowController] = []
    let chatWatcher = ChatWatcher()
    let meetingAlerts = MeetingAlerts()
    var chatStatus = ""
    var outsideSince: Date?
    var overviewEntered = false
    var hotKeys = HotKeys()
    var modeSink: AnyCancellable?

    func applicationDidFinishLaunching(_ n: Notification) {
        try? FileManager.default.createDirectory(atPath: eventsDir, withIntermediateDirectories: true)
        try? "\(getpid())".write(toFile: notifierDir + "/island.pid", atomically: true, encoding: .utf8)
        buildWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.buildWindows() }

        model.refreshSessions()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.model.refreshSessions() }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.drainEvents { self.screenUnderMouse() }
        }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.trackMouse() }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.model.mode == .overview else { return }
            self.model.collapse()
        }

        // Control-Option-C toggles the overview, Control-Option-T opens Tasks ready to type; Escape closes.
        hotKeys.install { [weak self] id in
            guard let self else { return }
            switch id {
            case HotKeys.toggleID:
                if self.model.mode == .overview { self.model.collapse() } else { self.open(tab: .sessions) }
            case HotKeys.tasksID:
                if self.model.mode == .overview && self.model.tab == .tasks { self.model.collapse() } else { self.open(tab: .tasks, type: true) }
            case HotKeys.escapeID where self.model.mode == .overview:
                if self.model.sending != nil {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) { self.model.sending = nil }
                } else if self.model.expanded != nil {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { self.model.expanded = nil }
                } else {
                    self.model.collapse()
                }
            default: break
            }
        }
        hotKeys.register(id: HotKeys.toggleID, key: UInt32(kVK_ANSI_C), mods: UInt32(controlKey | optionKey))
        hotKeys.register(id: HotKeys.tasksID, key: UInt32(kVK_ANSI_T), mods: UInt32(controlKey | optionKey))
        modeSink = model.$mode.removeDuplicates().sink { [weak self] m in
            guard let self else { return }
            if m == .overview {
                self.hotKeys.register(id: HotKeys.escapeID, key: UInt32(kVK_Escape), mods: 0)
                self.model.usage.refreshIfStale(45)
                self.model.reminders.reload()
            } else {
                self.hotKeys.unregister(id: HotKeys.escapeID)
                // give the keyboard back to the app you were in
                for c in self.controllers where c.panel.isKeyWindow {
                    c.panel.orderOut(nil)
                    c.panel.orderFrontRegardless()
                }
            }
        }

        // queues, usage, reminders
        model.queues.reload()
        model.usage.refresh()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.model.queues.reload() }
        Timer.scheduledTimer(withTimeInterval: 150, repeats: true) { [weak self] _ in self?.model.usage.refresh() }
        model.calendar.connect()
        // meetings come and go with the clock, not only with calendar changes
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.model.calendar.reload()
            self?.model.calendar.objectWillChange.send()
        }
        // meeting reminders and Google Chat messages as banners
        // fast: Chat withdraws its notification as soon as the message is read elsewhere
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let screen = self.controllers.first?.screen.id
            var events = self.chatWatcher.poll()
            events += self.meetingAlerts.due(self.model.calendar).map { self.meetingAlerts.event(for: $0) }
            if let e = events.last { self.model.show(e, on: screen) }
            let status = self.chatWatcher.readable ? "ok\n" : "no access: give Claude Island Full Disk Access\n"
            if status != self.chatStatus {
                self.chatStatus = status
                try? status.write(toFile: islandDir + "/chat-status.txt", atomically: true, encoding: .utf8)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.syncTasks() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.queues.prune(live: self.model.sessions)
        }
        installEditMenu()
    }

    func open(tab: OverviewTab, type: Bool = false) {
        guard let c = controllers.first else { return }
        model.tab = tab
        model.sending = nil
        if model.mode != .overview { model.openOverview(on: c.screen.id) }
        if type {
            model.focusTasksOnAppear = true
            model.focusRequest += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { c.panel.makeKey() }
        }
    }

    /// Queue tasks that came from Reminders: finished task -> reminder completed;
    /// reminder completed elsewhere (iPhone) while still queued -> task removed.
    func syncTasks() {
        let q = model.queues, r = model.reminders
        q.adopt(live: model.sessions)
        guard r.access == .ready else { return }
        for sq in q.queues.values {
            for t in sq.tasks {
                guard let rid = t.rid, !rid.hasPrefix("done:") else { continue }
                if t.state == "done" {
                    r.setDone(rid, true)
                    q.mutate(sid: sq.sid) { qq in
                        if let i = qq.tasks.firstIndex(where: { $0.id == t.id }) { qq.tasks[i].rid = "done:" + rid }
                    }
                } else if t.state == "queued", r.isDone(rid) == true {
                    q.remove(t.id, from: sq.sid)
                }
            }
        }
    }

    /// Accessory apps have no menu bar, but Cut/Copy/Paste/Undo shortcuts in text fields come from the main menu.
    func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func buildWindows() {
        controllers.forEach { $0.panel.orderOut(nil) }
        let infos = NSScreen.screens.map(ScreenInfo.init)
        let external = infos.filter { !$0.isBuiltin }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let target = external ?? infos.first else { controllers = []; return }
        controllers = [IslandWindowController(screen: target, model: model)]
    }

    func screenUnderMouse() -> CGDirectDisplayID? {
        let m = NSEvent.mouseLocation
        _ = m
        return controllers.first?.screen.id
    }

    func trackMouse() {
        // Option alone, held while a banner is up: open it to the whole message and keep it
        let flags = NSEvent.modifierFlags.intersection([.option, .command, .control, .shift])
        let held = flags == .option && model.mode == .banner
        if held != model.peek {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.peek = held }
            if held { model.pauseCollapse() } else if model.mode == .banner { model.scheduleCollapse(after: 1.2) }
        }
        let m = NSEvent.mouseLocation
        var hovered: CGDirectDisplayID?
        for c in controllers {
            let inside = c.islandRect(model).insetBy(dx: -2, dy: -2).contains(m)
            if c.panel.ignoresMouseEvents == inside { c.panel.ignoresMouseEvents = !inside }
            if inside { hovered = c.screen.id }
        }
        if model.hoverScreen != hovered {
            let wasOnBanner = model.mode == .banner && model.hoverScreen == model.activeScreen
            model.hoverScreen = hovered
            if model.mode == .banner {
                if hovered == model.activeScreen { model.pauseCollapse() } else if wasOnBanner { model.scheduleCollapse(after: 1.5) }
            }
        }
        // overview closes shortly after the pointer leaves it
        // (opened without the pointer, e.g. by an event: give it a few seconds before closing)
        if model.mode == .overview {
            if hovered == model.activeScreen {
                outsideSince = nil
                overviewEntered = true
            } else if controllers.contains(where: { $0.panel.isKeyWindow && $0.panel.firstResponder is NSTextView }) {
                outsideSince = nil   // typing in a field: stay open until Escape or a click elsewhere
            } else if let t = outsideSince {
                if Date().timeIntervalSince(t) > (overviewEntered ? 0.6 : 6) { model.collapse(); outsideSince = nil }
            } else {
                outsideSince = Date()
            }
        } else {
            outsideSince = nil
            overviewEntered = false
        }
    }
}

