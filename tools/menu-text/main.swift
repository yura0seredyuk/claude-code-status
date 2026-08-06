// Dev tool: prints the menu exactly as a user would read it, straight from the
// live state.json.  swiftc app/StatusIcon.swift tools/menu-text/main.swift
import AppKit

let path = NSHomeDirectory() + "/.claude/claude-status/state.json"
guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
    print("no state.json"); exit(0)
}
let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase
let file = try! decoder.decode(StateFile.self, from: data)
let records = file.sessions.values.filter { $0.isAlive }.sorted { $0.stamp > $1.stamp }

var best = Status.idle
for r in records where !r.isBackground {
    let eff: Status = (r.state == .done && Date().timeIntervalSince1970 - r.stamp > doneFadeAfter)
        ? .idle : r.state
    if eff.severity > best.severity { best = eff }
}
print("Claude Code — \(best.label)")
print(String(repeating: "─", count: 46))
for r in records {
    let eff: Status = (r.state == .done && Date().timeIntervalSince1970 - r.stamp > doneFadeAfter)
        ? .idle : r.state
    let lines = sessionLines(r, effective: eff)
    print("\(r.isBackground ? "[bg] " : "")\(lines.title)")
    if !lines.subtitle.isEmpty { print("      \(lines.subtitle)") }
}
