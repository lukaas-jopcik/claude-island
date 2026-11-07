// Subscription usage per Claude account (the same numbers as /usage in Claude Code).
//
// Accounts are the config dirs the `claude` wrapper switches between (~/.claude-work, ~/.claude-personal, ...).
// Each keeps its OAuth credentials in the login Keychain under "Claude Code-credentials-<sha256(dir)[0..8]>".
// We only read the access token Claude Code itself keeps fresh; we never refresh or store it.
import CryptoKit
import Foundation

struct UsageLimit: Equatable, Identifiable {
    let id: String
    let label: String
    let percent: Double
    let severity: String     // normal / warning / critical
    let resetsAt: Date?
}

struct Account: Equatable, Identifiable {
    let id: String           // config dir name, e.g. ".claude-work"
    let label: String        // "Work"
    let email: String
    let plan: String         // "Max 5x"
    var limits: [UsageLimit] = []
    var updated: Date?
    var problem: String?     // "Sign in again" etc.
}

func accountLabel(_ dir: String) -> String {
    var s = dir
    if s.hasPrefix(".claude-") { s.removeFirst(8) } else if s == ".claude" { return "Default" }
    return s.prefix(1).uppercased() + s.dropFirst()
}

final class UsageStore: ObservableObject {
    @Published var accounts: [String: Account] = [:]
    private var lastFetch = Date.distantPast
    private var fetching = false
    private let work = DispatchQueue(label: "claude-island.usage", qos: .utility)

    func refreshIfStale(_ maxAge: TimeInterval) {
        if Date().timeIntervalSince(lastFetch) > maxAge { refresh() }
    }

    func refresh() {
        guard !fetching else { return }
        fetching = true
        lastFetch = Date()
        let previous = accounts
        work.async {
            var out: [String: Account] = [:]
            for var a in Self.discover() {
                if let old = previous[a.id] { a.limits = old.limits; a.updated = old.updated }
                out[a.id] = Self.fetch(a)
            }
            DispatchQueue.main.async {
                self.fetching = false
                if out != self.accounts { self.accounts = out }
            }
        }
    }

    // MARK: discovery

    private struct Creds { let token: String; let expires: Date; let plan: String }

    private static func discover() -> [Account] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: homeDir) else { return [] }
        var out: [Account] = []
        for n in names.sorted() where n == ".claude" || n.hasPrefix(".claude-") {
            let dir = homeDir + "/" + n
            let cfg = n == ".claude" ? homeDir + "/.claude.json" : dir + "/.claude.json"
            guard let data = fm.contents(atPath: cfg),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oa = j["oauthAccount"] as? [String: Any] else { continue }
            out.append(Account(id: n, label: accountLabel(n), email: oa["emailAddress"] as? String ?? "", plan: ""))
        }
        return out
    }

    private static func service(for dirName: String) -> [String] {
        let path = homeDir + "/" + dirName
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        // the default dir is stored without a suffix when CLAUDE_CONFIG_DIR is unset
        return dirName == ".claude" ? ["Claude Code-credentials", "Claude Code-credentials-\(hash)"]
                                    : ["Claude Code-credentials-\(hash)"]
    }

    private static func credentials(_ dirName: String) -> Creds? {
        for svc in service(for: dirName) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["find-generic-password", "-s", svc, "-w"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let o = j["claudeAiOauth"] as? [String: Any],
                  let token = o["accessToken"] as? String else { continue }
            let exp = Date(timeIntervalSince1970: ((o["expiresAt"] as? Double) ?? 0) / 1000)
            return Creds(token: token, expires: exp, plan: planName(tier: o["rateLimitTier"] as? String, sub: o["subscriptionType"] as? String))
        }
        return nil
    }

    private static func planName(tier: String?, sub: String?) -> String {
        let t = tier ?? ""
        if t.contains("max_20x") { return "Max 20x" }
        if t.contains("max_5x") { return "Max 5x" }
        guard let s = sub, !s.isEmpty else { return "" }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    // MARK: fetch

    /// Demo mode: limits come from <ISLAND_HOME>/.claude/island/usage.json ({"<account id>": {"plan": "...", "limits": [[label, percent, minutesToReset], ...]}}).
    private static func demoFetch(_ account: Account) -> Account {
        let a = account
        guard let d = FileManager.default.contents(atPath: islandDir + "/usage.json"),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let o = j[a.id] as? [String: Any], let rows = o["limits"] as? [[Any]] else { return a }
        let limits = rows.compactMap { r -> UsageLimit? in
            guard r.count == 3, let label = r[0] as? String, let pct = (r[1] as? NSNumber)?.doubleValue,
                  let mins = (r[2] as? NSNumber)?.doubleValue else { return nil }
            return UsageLimit(id: label, label: label, percent: pct, severity: pct >= 90 ? "critical" : pct >= 70 ? "warning" : "normal",
                              resetsAt: Date().addingTimeInterval(mins * 60))
        }
        return Account(id: a.id, label: a.label, email: a.email, plan: o["plan"] as? String ?? "", limits: limits, updated: Date())
    }

    private static func fetch(_ account: Account) -> Account {
        if demoMode { return demoFetch(account) }
        var a = account
        guard let c = credentials(a.id) else { a.problem = "Signed out"; return a }
        a = Account(id: a.id, label: a.label, email: a.email, plan: c.plan, limits: a.limits, updated: a.updated)
        // Claude Code refreshes its own token while it runs; an expired one means the account is idle
        guard c.expires > Date() else { a.problem = a.limits.isEmpty ? "Signed out" : nil; return a }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
        req.setValue("Bearer \(c.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-island/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        var status = 0
        URLSession.shared.dataTask(with: req) { d, r, _ in
            body = d
            status = (r as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 12)
        guard status == 200, let d = body,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return a }
        let limits = parse(j)
        if !limits.isEmpty { a.limits = limits; a.updated = Date() }
        return a
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        if let d = iso.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }

    private static func parse(_ j: [String: Any]) -> [UsageLimit] {
        var out: [UsageLimit] = []
        if let limits = j["limits"] as? [[String: Any]] {
            for l in limits {
                let kind = l["kind"] as? String ?? ""
                let pct = (l["percent"] as? Double) ?? Double(l["percent"] as? Int ?? 0)
                var label: String
                switch kind {
                case "session": label = "Session"
                case "weekly_all": label = "Week"
                default:
                    let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                    guard let model, pct >= 1 else { continue }  // scoped limits only once they matter
                    label = "Week · \(model)"
                }
                out.append(UsageLimit(id: kind + label, label: label, percent: pct,
                                      severity: l["severity"] as? String ?? "normal", resetsAt: date(l["resets_at"])))
            }
        }
        if out.isEmpty {
            for (key, label) in [("five_hour", "Session"), ("seven_day", "Week")] {
                guard let o = j[key] as? [String: Any], let u = o["utilization"] as? Double else { continue }
                out.append(UsageLimit(id: key, label: label, percent: u,
                                      severity: u >= 90 ? "critical" : u >= 70 ? "warning" : "normal",
                                      resetsAt: date(o["resets_at"])))
            }
        }
        return out
    }
}

/// "in 1h 22m" / "at 23:00" / "Thu 09:00"
func resetText(_ d: Date?, now: Date) -> String {
    guard let d else { return "" }
    let s = Int(d.timeIntervalSince(now))
    if s <= 0 { return "resetting" }
    if s < 3600 { return "resets in \(max(1, s / 60))m" }
    if s < 6 * 3600 { return "resets in \(s / 3600)h \((s % 3600) / 60)m" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_GB")
    f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
    return "resets \(f.string(from: d))"
}
