// The overview: subscription usage per account, sessions with their queues, and the personal task list.
import SwiftUI

// MARK: - Layout (shared by the views and the island's size, so the shape always fits the content)

enum OV {
    static let width: CGFloat = 392
    static let pad: CGFloat = 8
    static let tabsH: CGFloat = 30
    static let rowH: CGFloat = 38
    static let gap: CGFloat = 4
    static let usageH: CGFloat = 62
    static let groupLabelH: CGFloat = 20
    static let groupGap: CGFloat = 6
    static let bottom: CGFloat = 10
    static let maxBody: CGFloat = 460

    // queue editor
    static let qPad: CGFloat = 8
    static let qHeader: CGFloat = 24
    static let qStatus: CGFloat = 16
    static let qTask: CGFloat = 24
    static let qField: CGFloat = 28
    static let qSpacing: CGFloat = 6

    // tasks tab
    static let inputH: CGFloat = 32
    static let taskH: CGFloat = 30
    static let chipsH: CGFloat = 32
    static let footerH: CGFloat = 22
    static let emptyH: CGFloat = 70
}

enum OverviewTab: String { case sessions, tasks }

struct SessionGroup: Identifiable {
    let id: String
    let account: Account?
    let sessions: [Session]
    let showLabel: Bool

    var headerH: CGFloat {
        if let a = account, !a.limits.isEmpty { return OV.usageH }
        return showLabel ? OV.groupLabelH : 0
    }
}

/// Sessions grouped by the account they run on; the account's usage heads each group.
func sessionGroups(_ sessions: [Session], _ usage: [String: Account]) -> [SessionGroup] {
    let withUsage = usage.values.filter { !$0.limits.isEmpty }.sorted { $0.id < $1.id }
    let fallback = withUsage.first?.id ?? ""
    var order: [String] = []
    var by: [String: [Session]] = [:]
    for s in sessions {
        let a = s.account.isEmpty ? fallback : s.account
        if by[a] == nil { order.append(a) }
        by[a, default: []].append(s)
    }
    if order.isEmpty, let a = withUsage.first { return [SessionGroup(id: a.id, account: a, sessions: [], showLabel: false)] }
    let multi = order.count > 1
    return order.map { SessionGroup(id: $0, account: usage[$0], sessions: by[$0] ?? [], showLabel: multi) }
}

func queueTasksShown(_ q: SessionQueue?) -> [QTask] {
    guard let q else { return [] }
    let done = q.tasks.filter { $0.state == "done" }.suffix(2)
    return Array(done) + q.tasks.filter { $0.state != "done" }
}

func queueStatus(_ s: Session, _ q: SessionQueue?, globalPaused: Bool) -> (String, Color)? {
    guard let q else { return nil }
    if globalPaused && q.active { return ("All queues are paused", Color(hex: 0xfab387)) }
    if q.isPaused {
        let r = (q.pauseReason ?? "").isEmpty ? "Paused" : q.pauseReason!
        return (r + " · resume with ▶", Color(hex: 0xfab387))
    }
    if let r = q.running, s.status != "working" {
        let why = (r.note ?? "").isEmpty ? "Waiting for your reply in the session" : r.note!
        let w = why.prefix(1).uppercased() + why.dropFirst()
        return (w, Kind.blocked.accent)
    }
    if q.running == nil, !q.queued.isEmpty, s.kind != .working {
        return ("Starts after this session's next reply", Pal.overlay)
    }
    return nil
}

func queueEditorHeight(_ s: Session, _ q: SessionQueue?, globalPaused: Bool) -> CGFloat {
    let rows = CGFloat(queueTasksShown(q).count)
    var h = OV.qPad * 2 + OV.qHeader + OV.qField * 2 + OV.qSpacing * 2
    if queueStatus(s, q, globalPaused: globalPaused) != nil { h += OV.qStatus + OV.qSpacing }
    if rows > 0 { h += rows * OV.qTask + OV.qSpacing }
    return h
}

extension IslandModel {
    func overviewBodyHeight() -> CGFloat {
        switch tab {
        case .sessions:
            let groups = sessionGroups(sessions, usage.accounts)
            if sessions.isEmpty { return (groups.first?.headerH ?? 0) + 46 }
            var h: CGFloat = 0
            for (i, g) in groups.enumerated() {
                if i > 0 { h += OV.groupGap }
                h += g.headerH
                h += CGFloat(g.sessions.count) * OV.rowH + CGFloat(max(0, g.sessions.count - 1)) * OV.gap
                if let e = expanded, let s = g.sessions.first(where: { $0.id == e }) {
                    h += OV.gap + queueEditorHeight(s, queues.queues[s.id], globalPaused: queues.globalPaused)
                }
            }
            return h
        case .tasks:
            var h = OV.inputH + OV.gap + OV.footerH
            if reminders.access != .ready || reminders.items.isEmpty {
                h += OV.emptyH
            } else {
                h += CGFloat(reminders.items.count) * OV.taskH
                if let s = sending, reminders.items.contains(where: { $0.id == s }) { h += OV.chipsH }
            }
            return h
        }
    }

    func overviewHeight(_ screen: ScreenInfo) -> CGFloat {
        let band: CGFloat = screen.hasNotch ? screen.notchH : 28
        return band + OV.tabsH + 6 + min(overviewBodyHeight(), OV.maxBody) + OV.bottom
    }
}

// MARK: - Small pieces

enum Tint {
    static let blue = Color(hex: 0x89b4fa)
    static let sapphire = Color(hex: 0x74c7ec)
    static let teal = Color(hex: 0x94e2d5)
    static let green = Color(hex: 0xa6e3a1)
    static let peach = Color(hex: 0xfab387)
    static let red = Color(hex: 0xf38ba8)
    static let mauve = Color(hex: 0xcba6f7)
    static let lavender = Color(hex: 0xb4befe)
}

struct HoverButton: View {
    let symbol: String
    var size: CGFloat = 11
    var tint: Color = Pal.subtext
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(hover ? Pal.text : tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(help)
    }
}

/// Plain text field on a soft glass capsule; the rim lights up in the accent color while editing.
struct GlassField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var accent: Color = Tint.mauve
    var height: CGFloat = OV.qField
    var focus: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(focus.wrappedValue ? accent : Pal.overlay)
            }
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Pal.overlay))
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Pal.text)
                .focused(focus)
                .onSubmit(onSubmit)
            if focus.wrappedValue && !text.isEmpty {
                Image(systemName: "return")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(accent.opacity(0.8))
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: height - 4)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(focus.wrappedValue ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focus.wrappedValue ? accent.opacity(0.55) : .white.opacity(0.06), lineWidth: 1)
        )
        .frame(height: height)
        .animation(.easeOut(duration: 0.18), value: focus.wrappedValue)
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
    }
}

/// Queue position on a session that waits for you: soft capsule with a slowly breathing dot.
struct WaitingPill: View {
    let text: String
    let color: Color
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
                .shadow(color: color, radius: breathe ? 3 : 0)
                .opacity(breathe ? 1 : 0.45)
            Text(text).font(.system(size: 9.5, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .frame(height: 16)
        .background(Capsule().fill(color.opacity(0.12)))
        .onAppear { withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { breathe = true } }
    }
}

struct Pill: View {
    let text: String
    var symbol: String? = nil
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            Text(text).font(.system(size: 9.5, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.5))
    }
}

// MARK: - Usage

struct Meter: View {
    let limit: UsageLimit

    var colors: [Color] {
        let p = limit.percent
        if limit.severity == "critical" || p >= 95 { return [Color(hex: 0xeba0ac), Tint.red] }
        if limit.severity == "warning" || p >= 75 { return [Color(hex: 0xf9e2af), Tint.peach] }
        return [Tint.sapphire, Tint.blue]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Pal.subtext)
                Spacer(minLength: 4)
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(limit.percent >= 75 ? colors[1] : Pal.text)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, g.size.width * min(1, limit.percent / 100)))
                        .shadow(color: colors[1].opacity(0.55), radius: 4)
                }
            }
            .frame(height: 4)
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(limit.percent >= 100 ? "Limit reached · " + resetText(limit.resetsAt, now: ctx.date) : resetText(limit.resetsAt, now: ctx.date))
                    .font(.system(size: 9.5))
                    .foregroundStyle(limit.percent >= 100 ? colors[1].opacity(0.85) : Pal.overlay)
                    .lineLimit(1)
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: limit.percent)
    }
}

struct UsageHeader: View {
    let group: SessionGroup

    var body: some View {
        if let a = group.account, !a.limits.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(a.label.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .kerning(0.6)
                        .foregroundStyle(Pal.overlay)
                    if !a.plan.isEmpty {
                        Text(a.plan)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Pal.overlay.opacity(0.7))
                    }
                    Spacer()
                    if let u = a.updated, Date().timeIntervalSince(u) > 600 {
                        Text("updated \(elapsed(since: u, now: Date())) ago")
                            .font(.system(size: 9))
                            .foregroundStyle(Pal.overlay.opacity(0.7))
                    }
                }
                HStack(spacing: 14) {
                    ForEach(a.limits.prefix(2)) { Meter(limit: $0) }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: OV.usageH, alignment: .top)
        } else if group.showLabel {
            HStack {
                Text((group.account?.label ?? accountLabel(group.id)).uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(Pal.overlay)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: OV.groupLabelH)
        }
    }
}

// MARK: - Sessions

struct SessionRow: View {
    let session: Session
    let queue: SessionQueue?
    let globalPaused: Bool
    let expanded: Bool
    let index: Int
    let toggle: () -> Void
    @State private var hover = false
    @State private var shown = false

    @ViewBuilder var badge: some View {
        if let q = queue, q.active || q.isPaused {
            if q.running != nil && session.status != "working" {
                let done = q.tasks.filter { $0.state == "done" }.count
                WaitingPill(text: "\(done + 1) of \(done + 1 + q.queued.count)", color: Kind.blocked.accent)
            } else if q.isPaused || (globalPaused && q.active) {
                Pill(text: "Paused", symbol: "pause.fill", color: Tint.peach)
            } else if q.running != nil {
                let done = q.tasks.filter { $0.state == "done" }.count
                Pill(text: "Task \(done + 1) of \(done + 1 + q.queued.count)", symbol: "bolt.fill", color: Tint.blue)
            } else {
                Pill(text: "\(q.queued.count) queued", color: Tint.mauve)
            }
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Glyph(kind: session.kind, size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Pal.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(session.kind.needsAttention ? session.kind.accent : Pal.subtext)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 6)
            Button(action: toggle) { badge }.buttonStyle(.plain)
            if hover || expanded {
                HoverButton(symbol: expanded ? "chevron.up" : "plus", size: 10.5,
                            tint: expanded ? Tint.mauve : Pal.subtext,
                            help: expanded ? "Close queue" : "Queue a task for this session", action: toggle)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(elapsed(since: session.since, now: ctx.date))
                        .font(monoFont)
                        .foregroundStyle(Pal.overlay)
                        .monospacedDigit()
                }
                .frame(minWidth: 22, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: OV.rowH)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.white.opacity(expanded ? 0.06 : hover ? 0.07 : 0))
                if session.kind == .blocked {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [Kind.blocked.accent.opacity(0.13), Kind.blocked.accent.opacity(0.02)],
                                             startPoint: .leading, endPoint: .trailing))
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Kind.blocked.accent.opacity(0.28), .clear],
                                                     startPoint: .leading, endPoint: .trailing), lineWidth: 0.6)
                }
            }
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onTapGesture { focusSession(term: session.term, cwd: session.cwd, tty: session.tty, glow: session.kind.accent) }
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : -10)
        .scaleEffect(shown ? 1 : 0.94, anchor: .top)
        .blur(radius: shown ? 0 : 5)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78).delay(0.12 + Double(index) * 0.04)) { shown = true }
        }
    }

    var subtitle: String {
        if session.kind == .working, let r = queue?.running { return "Queue · " + r.text }
        return session.subtitle
    }
}

struct ProfilePicker: View {
    let value: Profile
    let set: (Profile) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Profile.allCases) { p in
                Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { set(p) } } label: {
                    Text(p.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(value == p ? Pal.text : Pal.overlay)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background {
                            if value == p {
                                Capsule().fill(.white.opacity(0.12))
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "profile", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(p.hint)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.05)))
    }
}

struct TaskLine: View {
    let task: QTask
    let remove: () -> Void
    var markDone: () -> Void = {}
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Group {
                switch task.state {
                case "running":
                    Image(systemName: "sparkle").foregroundStyle(Tint.blue).symbolEffect(.pulse, options: .repeating)
                case "done":
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Tint.green)
                default:
                    Image(systemName: "circle").foregroundStyle(Pal.overlay)
                }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .frame(width: 14)
            Text(task.text)
                .font(.system(size: 11))
                .foregroundStyle(task.state == "done" ? Pal.overlay : Pal.text)
                .strikethrough(task.state == "done", color: Pal.overlay.opacity(0.6))
                .lineLimit(1)
            if task.rid != nil {
                Image(systemName: "checklist").font(.system(size: 8.5)).foregroundStyle(Tint.mauve.opacity(0.7))
                    .help("From your Reminders list")
            }
            Spacer(minLength: 4)
            if hover && task.state == "running" {
                HoverButton(symbol: "checkmark", size: 9, tint: Tint.green, help: "Mark done (the queue moves on after the next reply)", action: markDone)
                    .transition(.opacity)
            } else if hover {
                HoverButton(symbol: "xmark", size: 8.5, help: "Remove", action: remove)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: OV.qTask)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

struct QueueEditor: View {
    let session: Session
    let queue: SessionQueue?
    @ObservedObject var store: QueueStore
    @State private var draft = ""
    @State private var instructions = ""
    @FocusState private var draftFocus: Bool
    @FocusState private var instrFocus: Bool

    var profile: Profile { Profile(rawValue: queue?.profile ?? "continue") ?? .continue }

    var body: some View {
        VStack(alignment: .leading, spacing: OV.qSpacing) {
            HStack(spacing: 6) {
                ProfilePicker(value: profile) { p in store.mutate(session) { $0.profile = p.rawValue } }
                Spacer(minLength: 4)
                Button {
                    let steps = [1, 2, 3, 5, 8]  // Claude Code ends a turn after 8 Stop-hook blocks in a row
                    let cur = queue?.limit ?? 3
                    let next = steps.first { $0 > cur } ?? steps[0]
                    store.mutate(session) { $0.maxChain = next }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "repeat").font(.system(size: 9, weight: .bold))
                        Text("\(queue?.limit ?? 3)").font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    .foregroundStyle(Pal.subtext)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(.white.opacity(0.06)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Tasks in a row before it pauses for you to check")
                if let q = queue, q.active || q.isPaused {
                    HoverButton(symbol: q.isPaused ? "play.fill" : "pause.fill", size: 9.5,
                                tint: q.isPaused ? Tint.green : Pal.subtext,
                                help: q.isPaused ? "Resume" : "Pause this queue") {
                        store.setPaused(session.id, !q.isPaused)
                    }
                }
                if queue?.tasks.contains(where: { $0.state == "done" }) == true {
                    HoverButton(symbol: "checkmark.circle.badge.xmark", size: 10, help: "Clear finished") {
                        store.clearDone(session.id)
                    }
                }
            }
            .frame(height: OV.qHeader)

            if let (text, color) = queueStatus(session, queue, globalPaused: store.globalPaused) {
                Text(text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(height: OV.qStatus)
                    .transition(.opacity)
            }

            let tasks = queueTasksShown(queue)
            if !tasks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(tasks) { t in
                        TaskLine(task: t, remove: { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.remove(t.id, from: session.id) } },
                                 markDone: { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.markDone(t.id, in: session.id) } })
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity.combined(with: .scale(scale: 0.95))))
                    }
                }
            }

            GlassField(placeholder: "Add a task for \(session.name)…", text: $draft, icon: "plus",
                       focus: $draftFocus) {
                let t = draft
                draft = ""
                withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { store.add(t, to: session) }
            }
            GlassField(placeholder: "How it should carry on (optional)", text: $instructions, icon: "text.bubble",
                       accent: Tint.blue, focus: $instrFocus) { saveInstructions() }
        }
        .padding(OV.qPad)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.045))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
        )
        .onAppear {
            instructions = queue?.instructions ?? ""
        }
        .onChange(of: instrFocus) { _, f in if !f { saveInstructions() } }
        .onDisappear { saveInstructions() }
    }

    func saveInstructions() {
        let t = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != (queue?.instructions ?? "") else { return }
        store.mutate(session) { $0.instructions = t }
    }
}

struct SessionsPane: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var queues: QueueStore
    @ObservedObject var usage: UsageStore

    var body: some View {
        let groups = sessionGroups(model.sessions, usage.accounts)
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { gi, g in
                if gi > 0 { Color.clear.frame(height: OV.groupGap) }
                UsageHeader(group: g)
                VStack(spacing: OV.gap) {
                    ForEach(Array(g.sessions.enumerated()), id: \.element.id) { i, s in
                        SessionRow(session: s, queue: queues.queues[s.id], globalPaused: queues.globalPaused,
                                   expanded: model.expanded == s.id, index: i) {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                                model.expanded = model.expanded == s.id ? nil : s.id
                            }
                        }
                        if model.expanded == s.id {
                            QueueEditor(session: s, queue: queues.queues[s.id], store: queues)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: -8)).animation(.spring(response: 0.4, dampingFraction: 0.85).delay(0.05)),
                                    removal: .opacity.animation(.easeIn(duration: 0.1))))
                        }
                    }
                }
            }
            if model.sessions.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 12))
                    .foregroundStyle(Pal.overlay)
                    .frame(height: 46)
            }
        }
    }
}

// MARK: - Tasks (Apple Reminders)

struct ReminderRow: View {
    let item: ReminderItem
    let link: (Session?, QTask)?
    let sending: Bool
    let toggle: () -> Void
    let send: () -> Void
    let delete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Button(action: toggle) {
                ZStack {
                    Circle().strokeBorder(item.done ? Tint.mauve : Pal.overlay.opacity(0.8), lineWidth: 1.2)
                    if item.done {
                        Circle().fill(LinearGradient(colors: [Tint.mauve, Color(hex: 0x8839ef)], startPoint: .top, endPoint: .bottom))
                            .padding(2.5)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    }
                }
                .frame(width: 15, height: 15)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: item.done)

            Text(item.title)
                .font(.system(size: 11.5))
                .foregroundStyle(item.done ? Pal.overlay : Pal.text)
                .strikethrough(item.done, color: Pal.overlay.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let (s, t) = link {
                Pill(text: s?.name ?? "queued", symbol: t.state == "running" ? "bolt.fill" : t.state == "done" ? "checkmark" : "arrow.turn.down.right",
                     color: t.state == "running" ? Tint.blue : t.state == "done" ? Tint.green : Tint.mauve)
            }
            if hover && !item.done {
                if link == nil {
                    HoverButton(symbol: sending ? "xmark" : "arrow.turn.down.right", size: 10,
                                tint: sending ? Tint.mauve : Pal.subtext, help: "Give it to a session", action: send)
                }
                HoverButton(symbol: "trash", size: 9.5, help: "Delete", action: delete)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: OV.taskH)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hover || sending ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

struct SessionChips: View {
    let sessions: [Session]
    let pick: (Session) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { i, s in
                    Button { pick(s) } label: {
                        HStack(spacing: 5) {
                            Circle().fill(s.kind.accent).frame(width: 6, height: 6)
                            Text(s.name).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Pal.text)
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(.white.opacity(0.08)))
                        .overlay(Capsule().strokeBorder(s.kind.accent.opacity(0.3), lineWidth: 0.5))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .modifier(PopIn(delay: 0.03 * Double(i)))
                }
            }
            .padding(.leading, 32)
        }
        .frame(height: OV.chipsH)
    }
}

struct TasksPane: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var reminders: RemindersStore
    @ObservedObject var queues: QueueStore
    @State private var draft = ""
    @FocusState private var focus: Bool

    func link(_ id: String) -> (Session?, QTask)? {
        for q in queues.queues.values {
            if let t = q.tasks.first(where: { $0.rid == id || $0.rid == "done:" + id }) {
                return (model.sessions.first { $0.id == q.sid }, t)
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassField(placeholder: reminders.access == .ready ? "New task…" : "Connect Reminders to add tasks",
                       text: $draft, icon: "plus", height: OV.inputH, focus: $focus) {
                let t = draft
                draft = ""
                withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { reminders.add(t) }
            }
            .disabled(reminders.access != .ready)
            Color.clear.frame(height: OV.gap)

            if reminders.access != .ready {
                connectCard.frame(height: OV.emptyH)
            } else if reminders.items.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "checklist").font(.system(size: 16)).foregroundStyle(Pal.overlay)
                    Text("Nothing on your list").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                }
                .frame(maxWidth: .infinity)
                .frame(height: OV.emptyH)
            } else {
                VStack(spacing: 0) {
                    ForEach(reminders.items) { item in
                        ReminderRow(item: item, link: link(item.id), sending: model.sending == item.id,
                                    toggle: { reminders.setDone(item.id, !item.done) },
                                    send: { withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                                        model.sending = model.sending == item.id ? nil : item.id } },
                                    delete: { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { reminders.delete(item.id) } })
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity.combined(with: .scale(scale: 0.96))))
                        if model.sending == item.id {
                            SessionChips(sessions: model.sessions) { s in
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                    queues.add(item.title, to: s, rid: item.id)
                                    model.sending = nil
                                }
                            }
                            .transition(.opacity.combined(with: .offset(y: -6)))
                        }
                    }
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "checklist").font(.system(size: 9))
                Text(reminders.access == .ready ? "Synced with “\(RemindersStore.listName)” in Reminders" : "Apple Reminders")
                    .font(.system(size: 9.5))
                Spacer()
                if reminders.access == .ready, !reminders.open.isEmpty {
                    Text("\(reminders.open.count) open").font(.system(size: 9.5)).monospacedDigit()
                }
            }
            .foregroundStyle(Pal.overlay.opacity(0.8))
            .padding(.horizontal, 8)
            .frame(height: OV.footerH)
        }
        .onChange(of: model.focusRequest) { _, _ in
            if model.tab == .tasks { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focus = true } }
        }
        .onAppear {
            if model.focusTasksOnAppear {
                model.focusTasksOnAppear = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focus = true }
            }
        }
    }

    @ViewBuilder var connectCard: some View {
        VStack(spacing: 7) {
            Text(reminders.access == .denied ? "Reminders access is off" : "Keep your tasks in Apple Reminders")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Pal.text)
            if reminders.access == .denied {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                }
                .buttonStyle(CapsuleButton(color: Tint.peach))
            } else {
                Button("Connect Reminders") { reminders.connect() }
                    .buttonStyle(CapsuleButton(color: Tint.mauve))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct CapsuleButton: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color(hex: 0x1e1e2e))
            .padding(.horizontal, 12)
            .frame(height: 22)
            .background(Capsule().fill(color.opacity(configuration.isPressed ? 0.75 : 1)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Overview

struct TabSwitch: View {
    @ObservedObject var model: IslandModel
    let sessions: Int
    let tasks: Int
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            tab(.sessions, "Sessions", sessions)
            tab(.tasks, "Tasks", tasks)
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.05)))
    }

    func tab(_ t: OverviewTab, _ title: String, _ count: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                model.tab = t
                model.sending = nil
            }
        } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 10.5, weight: .semibold))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(model.tab == t ? Pal.text.opacity(0.8) : Pal.overlay)
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(model.tab == t ? Pal.text : Pal.overlay)
            .padding(.horizontal, 12)
            .frame(height: 22)
            .background {
                if model.tab == t {
                    Capsule().fill(.white.opacity(0.12))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                        .matchedGeometryEffect(id: "tab", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct OverviewContent: View {
    let screen: ScreenInfo
    @ObservedObject var model: IslandModel
    @ObservedObject var queues: QueueStore
    @ObservedObject var usage: UsageStore
    @ObservedObject var reminders: RemindersStore

    var body: some View {
        let bodyH = model.overviewBodyHeight()
        VStack(spacing: 0) {
            // band beside / inside the notch
            HStack(spacing: 6) {
                Text("Claude Code")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Pal.overlay)
                Spacer()
                if queues.queues.values.contains(where: { $0.active }) || queues.globalPaused {
                    HoverButton(symbol: queues.globalPaused ? "play.fill" : "pause.fill", size: 9,
                                tint: queues.globalPaused ? Tint.peach : Pal.overlay,
                                help: queues.globalPaused ? "Resume all queues" : "Pause all queues") {
                        queues.toggleGlobalPause()
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: screen.hasNotch ? screen.notchH : 28)

            HStack {
                TabSwitch(model: model, sessions: model.sessions.count, tasks: reminders.open.count)
                Spacer()
            }
            .padding(.horizontal, OV.pad + 2)
            .frame(height: OV.tabsH)
            Color.clear.frame(height: 6)

            Group {
                if bodyH > OV.maxBody {
                    ScrollView(.vertical, showsIndicators: false) { pane.padding(.bottom, 14) }
                        .frame(height: OV.maxBody)
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9),
                                                     .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                } else {
                    pane
                }
            }
            .padding(.horizontal, OV.pad)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder var pane: some View {
        switch model.tab {
        case .sessions:
            SessionsPane(model: model, queues: queues, usage: usage)
                .transition(.opacity.combined(with: .offset(x: -12)))
        case .tasks:
            TasksPane(model: model, reminders: reminders, queues: queues)
                .transition(.opacity.combined(with: .offset(x: 12)))
        }
    }
}
