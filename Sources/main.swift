// Entry point of Claude Island (see Island.swift).
import AppKit

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--resolve" {
    if let w = zedWorkspace(for: CommandLine.arguments[2]) { print(w.id, w.roots.joined(separator: " | ")) } else { print("none") }
    exit(0)
}

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--tab" {
    let cwd = CommandLine.arguments[2], tty = CommandLine.arguments[3]
    if let w = zedWorkspace(for: cwd), let t = zedTabTarget(workspace: w.id, cwd: cwd, tty: tty) {
        print("workspace", w.id, "pane", t.pane, "tab", t.item, "activePane", t.activePane, "keys", ZedKeys.sequence(for: t).joined(separator: " "))
    } else { print("none") }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
