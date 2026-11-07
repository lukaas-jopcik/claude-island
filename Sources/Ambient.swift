// What the drawn notch on an external monitor shows at rest. Unlike a hardware notch it hides nothing,
// so it carries a quiet summary: a dot per live session,
// the next meeting from the chosen calendars and the limit that binds first.
import AppKit
import EventKit
import SwiftUI

// MARK: - Calendar

struct Meeting: Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: Color
    let join: URL?
}

/// Next meetings from the calendars whose name or account matches ~/.claude/island/calendars.conf
/// (one keyword per line; without the file every calendar is used).
final class CalendarStore: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var access = false
    private let store = EKEventStore()
    private var observing = false

    init() {
        if demoMode { access = true; return }
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { access = true; start() }
    }

    func connect() {
        if demoMode { reload(); return }
        guard !access, EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                self.access = granted
                if granted { self.start() }
            }
        }
    }

    private func start() {
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                self?.reload()
            }
        }
        reload()
    }

    private var keywords: [String] {
        guard let raw = try? String(contentsOfFile: islandDir + "/calendars.conf", encoding: .utf8) else { return [""] }
        return raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    func reload() {
        guard access else { return }
        if demoMode {   // two made-up meetings relative to now, so the notch always has something to show
            let now = Date()
            let list = [Meeting(id: "demo1", title: "Design review", start: now.addingTimeInterval(14 * 60),
                                end: now.addingTimeInterval(74 * 60), color: Tint.blue, join: URL(string: "https://meet.example.com/design")),
                        Meeting(id: "demo2", title: "Launch sync", start: now.addingTimeInterval(3 * 3600),
                                end: now.addingTimeInterval(4 * 3600), color: Tint.blue, join: nil)]
            if list != meetings { meetings = list }
            return
        }
        store.refreshSourcesIfNecessary()
        let all = store.calendars(for: .event)
        let keys = keywords
        let chosen = all.filter { c in
            let hay = (c.title + " " + c.source.title).lowercased()
            return keys.contains { hay.contains($0) }
        }
        // what the island can see, so the keywords are easy to pick (names only)
        let seen = all.map { ($0.source.title, $0.title, chosen.contains($0) ? "*" : " ") }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map { "\($0.2) \($0.0) / \($0.1)" }.joined(separator: "\n")
        try? (seen + "\n").write(toFile: islandDir + "/calendars.txt", atomically: true, encoding: .utf8)

        guard !chosen.isEmpty else { if !meetings.isEmpty { meetings = [] }; return }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(14 * 86400), calendars: chosen)
        let next = store.events(matching: pred)
            .filter { e in
                !e.isAllDay && e.status != .canceled && e.endDate > now
                    && !(e.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(6)
            .map { e in
                Meeting(id: e.calendarItemIdentifier, title: e.title ?? "Meeting", start: e.startDate, end: e.endDate,
                        color: Color(cgColor: e.calendar.cgColor), join: Self.joinLink(e))
            }
        var list = Array(next)
        if FileManager.default.fileExists(atPath: islandDir + "/meeting-demo") {  // preview only
            list.insert(Meeting(id: "demo", title: "Weekly sync", start: now.addingTimeInterval(4 * 60 + 20),
                                end: now.addingTimeInterval(3600), color: Tint.blue, join: URL(string: "https://meet.google.com/")), at: 0)
        }
        if list != meetings { meetings = list }
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        let upcoming = next.map { "  next \(f.string(from: $0.start))\($0.join != nil ? " (call)" : "")" }.joined(separator: "\n")
        try? (seen + "\n" + upcoming + "\n").write(toFile: islandDir + "/calendars.txt", atomically: true, encoding: .utf8)
    }

    private static func joinLink(_ e: EKEvent) -> URL? {
        let hosts = ["zoom.us", "teams.microsoft.com", "teams.live.com", "meet.google.com", "webex.com", "whereby.com", "around.co"]
        let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for m in det.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let u = m.url, let h = u.host?.lowercased(), hosts.contains(where: { h.hasSuffix($0) }) { return u }
        }
        return nil
    }

    /// The meeting worth showing: one that started less than 10 minutes ago, otherwise the next one.
    func current(at now: Date) -> Meeting? {
        meetings.first { m in
            (m.start <= now && now.timeIntervalSince(m.start) < 10 * 60 && m.end > now) || m.start > now
        }
    }

    func open(_ m: Meeting) {
        if let u = m.join { NSWorkspace.shared.open(u); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }
}

// MARK: - Model helpers

extension IslandModel {
    /// The most used limit of the accounts that have live sessions (all accounts when none runs).
    func ambientLimit(_ usage: UsageStore) -> UsageLimit? {
        let live = Set(sessions.map(\.account))
        let accounts = usage.accounts.values.filter { live.isEmpty || live.contains($0.id) }
        let pool = accounts.isEmpty ? Array(usage.accounts.values) : accounts
        return pool.flatMap(\.limits).max { $0.percent < $1.percent }
    }

    var ambientSessions: [Session] { sessions.sorted { $0.sortRank < $1.sortRank } }

    /// Width of the resting drawn notch for what it currently shows.
    func ambientWidth(_ usage: UsageStore, _ cal: CalendarStore, waiting: Bool = false) -> CGFloat {
        var w: CGFloat = 18
        let n = min(sessions.count, 7)
        if waiting { w += Ambient.leadW + 10 }
        else if n > 0 { w += CGFloat(n) * 8.5 + (sessions.count > 7 ? 18 : 0) }
        if cal.current(at: Date()) != nil { w += Ambient.meetingW + 10 }
        if ambientLimit(usage) != nil { w += 46 }
        return w
    }
}

enum Ambient {
    static let leadW: CGFloat = 150
    static let meetingW: CGFloat = 200
}

func limitColor(_ l: UsageLimit) -> Color {
    if l.severity == "critical" || l.percent >= 95 { return Tint.red }
    if l.severity == "warning" || l.percent >= 75 { return Tint.peach }
    return Tint.sapphire
}

// MARK: - Pieces

/// Thin ring that fills with the limit's use.
struct LimitRing: View {
    let limit: UsageLimit
    var size: CGFloat = 11
    var body: some View {
        let c = limitColor(limit)
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(1, max(0.02, limit.percent / 100)))
                .stroke(c, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: c.opacity(0.6), radius: 2)
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: limit.percent)
    }
}

/// A session as a dot in its state color; working ones breathe.
struct SessionDot: View {
    let kind: Kind
    @State private var breathe = false
    var body: some View {
        Circle()
            .fill(kind.accent)
            .frame(width: 5, height: 5)
            .shadow(color: kind.accent.opacity(0.7), radius: 2.5)
            .opacity(kind == .working ? (breathe ? 1 : 0.45) : (kind == .idle || kind == .done ? 0.55 : 1))
            .onAppear {
                guard kind == .working else { return }
                withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { breathe = true }
            }
            .id(kind)
    }
}

/// "Standup in 12m", warming up as it gets close; click joins the call (or opens Calendar).
struct MeetingChip: View {
    let store: CalendarStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            if let m = store.current(at: ctx.date) {
                let left = m.start.timeIntervalSince(ctx.date)
                let tint: Color = left <= 5 * 60 ? Tint.red : left <= 15 * 60 ? Tint.peach : Pal.subtext
                HStack(spacing: 5) {
                    if left <= 5 * 60 { PulseDot(color: Tint.red).scaleEffect(0.8).frame(width: 9) }
                    else { Circle().fill(m.color).frame(width: 5, height: 5) }
                    Text(m.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Pal.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(when(m, left: left))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .fixedSize()
                    if m.join != nil {
                        Image(systemName: "video.fill").font(.system(size: 8.5)).foregroundStyle(tint.opacity(0.8))
                    }
                }
                .frame(width: Ambient.meetingW, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture { store.open(m) }
                .help(m.join != nil ? "Join the call" : "Open Calendar")
            }
        }
    }

    func when(_ m: Meeting, left: TimeInterval) -> String {
        if left <= 0 { return "now" }
        let min = Int((left / 60).rounded(.up))
        if min < 60 { return "in \(min)m" }
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "HH:mm"
        if cal.isDateInToday(m.start) { return f.string(from: m.start) }
        if cal.isDateInTomorrow(m.start) { return "tomorrow " + f.string(from: m.start) }
        f.dateFormat = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: m.start).day ?? 9 < 7 ? "EEE HH:mm" : "d MMM HH:mm"
        return f.string(from: m.start)
    }
}

struct AmbientContent: View {
    let sessions: [Session]
    var attention: [Session] = []
    let limit: UsageLimit?
    @ObservedObject var calendar: CalendarStore

    var body: some View {
        HStack(spacing: 10) {
            if let a = attention.first {
                // who waits for you leads; the rest of the line stays
                HStack(spacing: 7) {
                    Glyph(kind: a.kind, size: 16).modifier(PopIn(delay: 0.1))
                    Text(attention.count > 1 ? "\(attention.count) waiting" : a.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Pal.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    PulseDot(color: a.kind.accent)
                }
                .frame(width: Ambient.leadW)
            } else if !sessions.isEmpty {
                HStack(spacing: 3.5) {
                    ForEach(sessions.prefix(7)) { s in SessionDot(kind: s.kind).transition(.scale.combined(with: .opacity)) }
                    if sessions.count > 7 {
                        Text("+\(sessions.count - 7)").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(Pal.overlay)
                    }
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
            if calendar.current(at: Date()) != nil { MeetingChip(store: calendar) }
            if let l = limit {
                HStack(spacing: 4) {
                    LimitRing(limit: l)
                    Text("\(Int(l.percent.rounded()))%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(l.percent >= 75 ? limitColor(l) : Pal.subtext)
                        .contentTransition(.numericText())
                        .fixedSize()
                }
                .help("\(l.label) limit · \(resetText(l.resetsAt, now: Date()))")
            }
        }
        .padding(.horizontal, 9)
        .frame(maxHeight: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: sessions.map(\.kind))
    }
}
