// Banners that are not about Claude sessions:
//   - a meeting from the chosen calendars is about to start (10 minutes before)
//   - a Google Chat message arrived (read from Notification Center's own database; needs Full Disk Access)
import AppKit
import SQLite3

final class MeetingAlerts {
    private var shown = Set<String>()

    /// Meetings that start within the next 10 minutes and were not announced yet.
    func due(_ cal: CalendarStore, now: Date = Date()) -> [Meeting] {
        cal.meetings.filter { m in
            let left = m.start.timeIntervalSince(now)
            return left > 0 && left <= 10 * 60 && !shown.contains(m.id + "\(m.start.timeIntervalSince1970)")
        }
    }

    func event(for m: Meeting, now: Date = Date()) -> IslandEvent {
        shown.insert(m.id + "\(m.start.timeIntervalSince1970)")
        let min = max(1, Int((m.start.timeIntervalSince(now) / 60).rounded()))
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return IslandEvent(kind: .meeting, title: m.title, message: "Starts in \(min) min · \(f.string(from: m.start))",
                           project: m.join != nil ? "Join call" : "", session: "", term: "", at: now,
                           url: m.join ?? URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }
}

/// New notifications of chosen apps (default: the Google Chat app), as they land in Notification Center.
final class ChatWatcher {
    private static let db = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
    private var lastID: Int64 = -1          // highest record seen; starts at the current end (no backlog)
    private(set) var readable = true

    /// Bundle ids from ~/.claude/island/notify-apps.conf (one per line), lowercase.
    private var apps: [String] {
        let raw = (try? String(contentsOfFile: islandDir + "/notify-apps.conf", encoding: .utf8))
            ?? "com.google.chrome.app.pommaclcbfghclhalboakcipcmmndhcj\n"   // Google Chat (Chrome app)
        return raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func appURL(_ bundle: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    }

    func poll() -> [IslandEvent] {
        if demoMode { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(Self.db)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); readable = false; return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var st: OpaquePointer?
        if lastID < 0 {
            guard sqlite3_prepare_v2(db, "select ifnull(max(rec_id), 0) from record", -1, &st, nil) == SQLITE_OK else {
                readable = false; return []
            }
            if sqlite3_step(st) == SQLITE_ROW { lastID = sqlite3_column_int64(st, 0) }
            sqlite3_finalize(st)
            readable = true
            return []
        }
        let sql = "select r.rec_id, a.identifier, r.data from record r join app a on a.app_id = r.app_id where r.rec_id > \(lastID) order by r.rec_id"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { readable = false; return [] }
        defer { sqlite3_finalize(st) }
        readable = true
        let watched = Set(apps)
        var out: [IslandEvent] = []
        while sqlite3_step(st) == SQLITE_ROW {
            lastID = max(lastID, sqlite3_column_int64(st, 0))
            let app = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
            // which apps post, for tuning the watch list (no content)
            if let h = FileHandle(forWritingAtPath: islandDir + "/notify-seen.log") ?? {
                FileManager.default.createFile(atPath: islandDir + "/notify-seen.log", contents: nil)
                return FileHandle(forWritingAtPath: islandDir + "/notify-seen.log") }() {
                h.seekToEndOfFile(); h.write("\(Date()) \(app)\n".data(using: .utf8)!); try? h.close()
            }
            // Chat in a Chrome tab (or without per-app attribution) posts as Chrome itself, with the site as subtitle
            let viaChrome = app.lowercased() == "com.google.chrome"
            guard watched.contains(app.lowercased()) || viaChrome, let blob = sqlite3_column_blob(st, 2) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(st, 2)))
            guard let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let req = p["req"] as? [String: Any] else { continue }
            let title = (req["titl"] as? String) ?? "Google Chat"
            var sub = (req["subt"] as? String) ?? ""
            var kind = Kind.chat
            if viaChrome {
                guard sub.contains("chat.google.com") || sub.contains("mail.google.com") else { continue }
                // Gmail hosts Chat too: only notifications that are not about chat are mail
                let iden = (req["iden"] as? String) ?? ""
                if sub.contains("mail.google.com") && !iden.contains("/chat") { kind = .mail }
                sub = ""
            }
            let body = (req["body"] as? String) ?? ""
            if kind == .mail {
                out.append(IslandEvent(kind: .mail, title: title, message: body.replacingOccurrences(of: "\n", with: " · "),
                                       project: "", session: "", term: "", at: Date(),
                                       url: URL(string: "https://mail.google.com/mail/u/0/#inbox")))
                continue
            }
            out.append(IslandEvent(kind: .chat, title: title, message: body.replacingOccurrences(of: "\n", with: " "),
                                   project: sub, session: "", term: "", at: Date(),
                                   url: appURL(viaChrome ? "com.google.Chrome.app.pommaclcbfghclhalboakcipcmmndhcj" : app)))
        }
        return out
    }
}
