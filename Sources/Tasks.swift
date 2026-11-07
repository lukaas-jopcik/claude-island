// Session queues (shared with ~/.claude/island/taskqueue.py) and personal tasks (Apple Reminders, list "Claude").
import EventKit
import Foundation

let islandDir = homeDir + "/.claude/island"
let queueDir = islandDir + "/queues"
let holdDir = islandDir + "/hold"
let globalPauseFile = islandDir + "/paused"

// MARK: - Queue model

struct QTask: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var state: String               // queued / running / done
    var added: Double?
    var started: Double?
    var finished: Double?
    var rid: String?                // linked reminder ("done:<id>" once synced back)
    var note: String?
}

struct SessionQueue: Codable, Equatable {
    var sid: String
    var cwd: String?
    var name: String?
    var profile: String?            // continue / verify / ship
    var instructions: String?
    var maxChain: Int?
    var chain: Int?
    var paused: Bool?
    var pauseKind: String?
    var pauseReason: String?
    var tasks: [QTask] = []
    var updated: Double?

    var queued: [QTask] { tasks.filter { $0.state == "queued" } }
    var running: QTask? { tasks.first { $0.state == "running" } }
    var isPaused: Bool { paused ?? false }
    var limit: Int { maxChain ?? 3 }
    var active: Bool { running != nil || !queued.isEmpty }
}

enum Profile: String, CaseIterable, Identifiable {
    case `continue`, verify, ship
    var id: String { rawValue }
    var title: String {
        switch self {
        case .continue: return "Continue"
        case .verify: return "Verify"
        case .ship: return "Ship"
        }
    }
    var hint: String {
        switch self {
        case .continue: return "Runs each task as written"
        case .verify: return "Tests and lint must pass before DONE"
        case .ship: return "Verify, then commit (never pushes)"
        }
    }
}

/// flock shared with taskqueue.py so the hook and the island never write over each other.
func withQueueLock<T>(_ body: () -> T) -> T {
    try? FileManager.default.createDirectory(atPath: queueDir, withIntermediateDirectories: true)
    let fd = open(queueDir + "/.lock", O_CREAT | O_RDWR, 0o600)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    return body()
}

final class QueueStore: ObservableObject {
    @Published var queues: [String: SessionQueue] = [:]
    @Published var globalPaused = false
    private var stamps: [String: Date] = [:]

    private func path(_ sid: String) -> String { queueDir + "/" + (sid as NSString).lastPathComponent + ".json" }

    private func read(_ sid: String) -> SessionQueue? {
        guard let d = FileManager.default.contents(atPath: path(sid)) else { return nil }
        return try? JSONDecoder().decode(SessionQueue.self, from: d)
    }

    private func write(_ q: SessionQueue) {
        var q = q
        q.updated = Date().timeIntervalSince1970
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(q) else { return }
        let p = path(q.sid), tmp = p + ".tmp"
        FileManager.default.createFile(atPath: tmp, contents: d, attributes: [.posixPermissions: 0o600])
        _ = rename(tmp, p)
    }

    /// Cheap poll: only files whose mtime changed are parsed again.
    func reload() {
        let fm = FileManager.default
        globalPaused = fm.fileExists(atPath: globalPauseFile)
        guard let files = try? fm.contentsOfDirectory(atPath: queueDir) else { if !queues.isEmpty { queues = [:] }; return }
        var next = queues
        var seen = Set<String>()
        for f in files where f.hasSuffix(".json") {
            let sid = String(f.dropLast(5))
            seen.insert(sid)
            let m = (try? fm.attributesOfItem(atPath: queueDir + "/" + f)[.modificationDate] as? Date) ?? nil
            if let m, stamps[sid] == m { continue }
            stamps[sid] = m
            if let q = read(sid) { next[sid] = q }
        }
        for k in next.keys where !seen.contains(k) { next[k] = nil; stamps[k] = nil }
        if next != queues { queues = next }
    }

    func mutate(_ s: Session, _ change: (inout SessionQueue) -> Void) {
        withQueueLock {
            var q = read(s.id) ?? SessionQueue(sid: s.id, cwd: s.cwd, name: s.name, profile: "continue", maxChain: 3, chain: 0, paused: false)
            q.cwd = s.cwd
            q.name = s.name
            change(&q)
            write(q)
        }
        reload()
    }

    func mutate(sid: String, _ change: (inout SessionQueue) -> Void) {
        withQueueLock {
            guard var q = read(sid) else { return }
            change(&q)
            write(q)
        }
        reload()
    }

    func add(_ text: String, to s: Session, rid: String? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        mutate(s) { q in
            q.tasks.append(QTask(id: UUID().uuidString.prefix(8).lowercased(), text: t, state: "queued",
                                 added: Date().timeIntervalSince1970, rid: rid))
            // finished history stays short
            let done = q.tasks.filter { $0.state == "done" }
            if done.count > 6 { let drop = Set(done.prefix(done.count - 6).map(\.id)); q.tasks.removeAll { drop.contains($0.id) } }
        }
    }

    func remove(_ taskID: String, from sid: String) { mutate(sid: sid) { q in q.tasks.removeAll { $0.id == taskID } } }

    /// You decide a running task is finished: it is done, and a pause it caused is lifted.
    func markDone(_ taskID: String, in sid: String) {
        mutate(sid: sid) { q in
            guard let i = q.tasks.firstIndex(where: { $0.id == taskID }) else { return }
            q.tasks[i].state = "done"
            q.tasks[i].finished = Date().timeIntervalSince1970
            if q.isPaused, q.pauseKind != "user" { q.paused = false; q.pauseKind = ""; q.pauseReason = "" }
            q.chain = 0
        }
    }

    func clearDone(_ sid: String) { mutate(sid: sid) { q in q.tasks.removeAll { $0.state == "done" } } }

    func setPaused(_ sid: String, _ paused: Bool) {
        mutate(sid: sid) { q in
            q.paused = paused
            q.pauseKind = paused ? "user" : ""
            q.pauseReason = paused ? "Paused" : ""
            if !paused { q.chain = 0 }
        }
    }

    func toggleGlobalPause() {
        if FileManager.default.fileExists(atPath: globalPauseFile) {
            try? FileManager.default.removeItem(atPath: globalPauseFile)
        } else {
            try? FileManager.default.createDirectory(atPath: islandDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: globalPauseFile, contents: Data())
        }
        reload()
    }

    /// Tell a pending "Up next" to wait (taskqueue.py polls for this file for a few seconds).
    func hold(_ sid: String) {
        try? FileManager.default.createDirectory(atPath: holdDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: holdDir + "/" + (sid as NSString).lastPathComponent, contents: Data())
    }

    /// A resumed session gets a new id: move an orphaned queue (same folder and name) over to it.
    func adopt(live: [Session]) {
        let liveIDs = Set(live.map(\.id))
        let orphans = queues.values.filter { !liveIDs.contains($0.sid) && $0.active }
        guard !orphans.isEmpty else { return }
        withQueueLock {
            for o in orphans {
                guard let s = live.first(where: { $0.cwd == o.cwd && $0.name == o.name && read($0.id) == nil }) else { continue }
                var q = o
                q.sid = s.id
                if let i = q.tasks.firstIndex(where: { $0.state == "running" }) { q.tasks[i].state = "queued" }
                write(q)
                try? FileManager.default.removeItem(atPath: path(o.sid))
            }
        }
        reload()
    }

    /// Queues of sessions that ended and have nothing left to do are removed after a day.
    func prune(live: [Session]) {
        let liveIDs = Set(live.map(\.id))
        let now = Date().timeIntervalSince1970
        for q in queues.values where !liveIDs.contains(q.sid) && !q.active && now - (q.updated ?? now) > 86400 {
            try? FileManager.default.removeItem(atPath: path(q.sid))
        }
    }
}

// MARK: - Apple Reminders

struct ReminderItem: Identifiable, Equatable {
    let id: String
    let title: String
    let done: Bool
    let created: Date
}

final class RemindersStore: ObservableObject {
    enum Access { case unknown, denied, ready }
    static let listName = "Claude"

    @Published var access: Access = .unknown
    @Published var items: [ReminderItem] = []
    private let store = EKEventStore()
    private var calendar: EKCalendar?
    private var observing = false

    var open: [ReminderItem] { items.filter { !$0.done } }

    init() {
        if demoMode {
            access = .ready
            let now = Date()
            items = [("Reply to the design review notes", 0), ("Book flights for the offsite", 1), ("Renew the domain", 2)]
                .map { ReminderItem(id: "demo\($0.1)", title: $0.0, done: false, created: now.addingTimeInterval(Double($0.1))) }
            return
        }
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: access = .ready; start()
        case .denied, .restricted, .writeOnly: access = .denied
        default: access = .unknown
        }
    }

    func connect() {
        store.requestFullAccessToReminders { granted, _ in
            DispatchQueue.main.async {
                self.access = granted ? .ready : .denied
                if granted { self.start() }
            }
        }
    }

    private func start() {
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                self?.calendar = nil
                self?.reload()
            }
        }
        reload()
    }

    private func list() -> EKCalendar? {
        if let c = calendar { return c }
        let all = store.calendars(for: .reminder)
        if let c = all.first(where: { $0.title == Self.listName }) { calendar = c; return c }
        // create it next to the default list (iCloud when available, so it reaches the iPhone)
        guard let source = store.defaultCalendarForNewReminders()?.source ?? all.first?.source else { return nil }
        let c = EKCalendar(for: .reminder, eventStore: store)
        c.title = Self.listName
        c.source = source
        c.cgColor = CGColor(srgbRed: 0.80, green: 0.65, blue: 0.97, alpha: 1)  // mauve
        do { try store.saveCalendar(c, commit: true) } catch { return nil }
        calendar = c
        return c
    }

    func reload() {
        guard !demoMode, access == .ready, let cal = list() else { return }
        let pred = store.predicateForReminders(in: [cal])
        store.fetchReminders(matching: pred) { rs in
            let cutoff = Date().addingTimeInterval(-6 * 3600)
            let items = (rs ?? [])
                .filter { !$0.isCompleted || ($0.completionDate ?? .distantPast) > cutoff }
                .map { ReminderItem(id: $0.calendarItemIdentifier, title: $0.title ?? "", done: $0.isCompleted,
                                    created: $0.creationDate ?? .distantPast) }
                .sorted { ($0.done ? 1 : 0, $0.created) < ($1.done ? 1 : 0, $1.created) }
            DispatchQueue.main.async { if items != self.items { self.items = items } }
        }
    }

    private func reminder(_ id: String) -> EKReminder? { store.calendarItem(withIdentifier: id) as? EKReminder }

    func add(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if demoMode { if !t.isEmpty { items.append(ReminderItem(id: UUID().uuidString, title: t, done: false, created: Date())) }; return }
        guard !t.isEmpty, let cal = list() else { return }
        let r = EKReminder(eventStore: store)
        r.title = t
        r.calendar = cal
        try? store.save(r, commit: true)
        reload()
    }

    func setDone(_ id: String, _ done: Bool) {
        if demoMode { items = items.map { $0.id == id ? ReminderItem(id: $0.id, title: $0.title, done: done, created: $0.created) : $0 }; return }
        guard let r = reminder(id), r.isCompleted != done else { return }
        r.isCompleted = done
        try? store.save(r, commit: true)
        reload()
    }

    func delete(_ id: String) {
        if demoMode { items.removeAll { $0.id == id }; return }
        guard let r = reminder(id) else { return }
        try? store.remove(r, commit: true)
        reload()
    }

    func isDone(_ id: String) -> Bool? { demoMode ? items.first { $0.id == id }?.done : reminder(id).map(\.isCompleted) }
}
