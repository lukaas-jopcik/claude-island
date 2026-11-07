// Jump to the exact terminal tab of a session in Zed.
//
// Zed has no API for this, so:
//   1. Zed's own state DB tells us the terminal panel layout of the window: its panes, their tabs in order,
//      and the working directory of every terminal tab (kv_store "TerminalPanel"-"<workspace>", terminals).
//   2. Tabs that share a folder are told apart by creation order: DB rows (rowid) are created in the same
//      order as Zed's terminal processes start, and the session's tty belongs to one of those processes.
//   3. After the Zed CLI raised the window, hidden shortcuts that Claude Island added to ~/.config/zed/keymap.json
//      focus the terminal panel, walk to the right pane and activate the tab (needs Accessibility access).
import AppKit
import ApplicationServices
import SQLite3

struct ZedTabTarget {
    let pane: Int          // index of the pane inside the terminal panel
    let item: Int          // index of the tab inside that pane
    let activePane: Int    // pane that was active when Zed last saved
    let vertical: Bool     // panes stacked top to bottom
}

private struct PanelPane { let items: [Int64]; let active: Bool }

private func sqliteRows(_ sql: String, _ each: (OpaquePointer) -> Void) {
    let path = NSHomeDirectory() + "/Library/Application Support/Zed/db/0-stable/db.sqlite"
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 200)
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
    defer { sqlite3_finalize(st) }
    while sqlite3_step(st) == SQLITE_ROW { each(st) }
}

private func panelLayout(_ workspace: Int64) -> (panes: [PanelPane], vertical: Bool)? {
    var raw = ""
    sqliteRows("select value from kv_store where key = '\"TerminalPanel\"-\"\(workspace)\"'") { st in
        raw = sqlite3_column_text(st, 0).map { String(cString: $0) } ?? ""
    }
    guard let data = raw.data(using: .utf8),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = j["items"] as? [String: Any] else { return nil }
    func pane(_ p: [String: Any]) -> PanelPane {
        PanelPane(items: (p["children"] as? [NSNumber])?.map(\.int64Value) ?? [], active: p["active"] as? Bool ?? false)
    }
    if let p = items["Pane"] as? [String: Any] { return ([pane(p)], false) }
    // one level of splits; deeper nesting has no simple pane order to walk
    guard let g = items["Group"] as? [String: Any], let kids = g["children"] as? [[String: Any]] else { return nil }
    var panes: [PanelPane] = []
    for k in kids {
        guard let p = k["Pane"] as? [String: Any] else { return nil }
        panes.append(pane(p))
    }
    return (panes, (g["axis"] as? String) == "vertical")
}

/// Zed's terminal shells whose current folder is `cwd`, oldest first, as their ttys.
private func zedShellTTYs(in cwd: String) -> [String] {
    guard let zed = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.zed.Zed").first else { return [] }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-A", "-o", "pid=,ppid=,tty=,lstart=,comm="]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [] }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()

    struct Proc { let pid: Int32; let ppid: Int32; let tty: String; let start: Date; let comm: String }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    var procs: [Proc] = []
    for line in out.split(separator: "\n") {
        let c = line.split(separator: " ", omittingEmptySubsequences: true)
        guard c.count >= 9, let pid = Int32(c[0]), let ppid = Int32(c[1]) else { continue }
        let start = f.date(from: c[3...7].joined(separator: " ")) ?? .distantPast
        procs.append(Proc(pid: pid, ppid: ppid, tty: String(c[2]), start: start, comm: c[8...].joined(separator: " ")))
    }
    // Zed runs each terminal as /usr/bin/login -> shell, parented to its main process
    let zedPIDs = Set(procs.filter { $0.comm.hasSuffix("/Zed.app/Contents/MacOS/zed") }.map(\.pid)).union([zed.processIdentifier])
    let logins = procs.filter { zedPIDs.contains($0.ppid) && $0.comm.hasSuffix("login") }
    var hits: [(Date, String)] = []
    for l in logins {
        guard let shell = procs.first(where: { $0.ppid == l.pid }), shellCwd(shell.pid) == cwd else { continue }
        hits.append((l.start, l.tty))
    }
    return hits.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.1)
}

private func shellCwd(_ pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafePointer(to: info.pvi_cdir.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
}

func zedTabTarget(workspace: Int64, cwd: String, tty: String) -> ZedTabTarget? {
    guard let (panes, vertical) = panelLayout(workspace) else { return nil }
    var dirs: [Int64: (String, Int64)] = [:]   // item -> (folder, rowid)
    sqliteRows("select item_id, working_directory_path, rowid from terminals where workspace_id = \(workspace)") { st in
        dirs[sqlite3_column_int64(st, 0)] = (sqlite3_column_text(st, 1).map { String(cString: $0) } ?? "", sqlite3_column_int64(st, 2))
    }
    let c = (cwd as NSString).standardizingPath
    var candidates: [(pane: Int, item: Int, rowid: Int64)] = []
    for (pi, p) in panes.enumerated() {
        for (ii, id) in p.items.enumerated() where dirs[id]?.0 == c {
            candidates.append((pi, ii, dirs[id]!.1))
        }
    }
    guard !candidates.isEmpty else { return nil }
    var pick = candidates[0]
    if candidates.count > 1, !tty.isEmpty {
        let ttys = zedShellTTYs(in: c)
        let ordered = candidates.sorted { $0.rowid < $1.rowid }
        if ttys.count == ordered.count, let i = ttys.firstIndex(of: tty) { pick = ordered[i] }
    }
    let active = panes.firstIndex(where: \.active) ?? 0
    return ZedTabTarget(pane: pick.pane, item: pick.item, activePane: active, vertical: vertical)
}

// MARK: - Keystrokes

enum ZedKeys {
    static let keymapMarker = "ctrl-alt-cmd-shift-f14"
    private static let codes: [String: CGKeyCode] = ["f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29]
    private static var asked = false

    /// The shortcuts exist in the user's Zed keymap and we may post keystrokes.
    static func ready() -> Bool {
        let km = (try? String(contentsOfFile: NSHomeDirectory() + "/.config/zed/keymap.json", encoding: .utf8)) ?? ""
        guard km.contains(keymapMarker) else { return false }
        if AXIsProcessTrusted() { return true }
        if !asked {
            asked = true
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        return false
    }

    static func sequence(for t: ZedTabTarget) -> [String] {
        var keys = ["f13", "f14"]                     // focus the center, then the terminal panel (its active pane)
        let d = t.pane - t.activePane
        let step = t.vertical ? (d > 0 ? "f18" : "f17") : (d > 0 ? "f16" : "f15")
        keys += Array(repeating: step, count: abs(d))
        if t.item < 10 { keys.append(t.item == 9 ? "0" : String(t.item + 1)) }
        return keys
    }

    /// Posts the hidden shortcuts once Zed is the frontmost app (gives up after ~1.5 s).
    static func send(_ keys: [String], then: @escaping () -> Void, attempt: Int = 0) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "dev.zed.Zed"
        if !front {
            if attempt < 15 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { send(keys, then: then, attempt: attempt + 1) } }
            else { then() }
            return
        }
        // let a Space switch settle before typing into the window
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.08 : 0.3)) {
            let src = CGEventSource(stateID: .hidSystemState)
            let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
            var delay = 0.0
            for k in keys {
                guard let code = codes[k] else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    for down in [true, false] {
                        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
                        e?.flags = flags
                        e?.post(tap: .cghidEventTap)
                    }
                }
                delay += 0.05
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { then() }
        }
    }
}
