// Assertions for the pure parts of app/StatusIcon.swift - the formatting and
// the decoding of what the hook writes. Compiled against the real file, so a
// change to either side of that seam fails here rather than in the menu.
//
//   swiftc -swift-version 5 app/StatusIcon.swift tests/swift/main.swift -o run
//   ./run <path to a limits.json written by the hook>

import AppKit

var failures = 0

func check(_ label: String, _ actual: String, _ expected: String) {
    if actual == expected {
        print("    ok   \(label)")
    } else {
        print("    FAIL \(label)\n         expected \(expected)\n         actual   \(actual)")
        failures += 1
    }
}

let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}()

// ---------------------------------------------------------------------------
print("  resetsInText")
// The boundaries are where this has gone wrong before: rounding minutes up
// inside an hours branch printed "60m", and promoting without re-deriving the
// hours printed "0h 59m".
for (seconds, expected) in [(30.0, "1m"), (59, "1m"), (61, "2m"), (3540, "59m"),
                            (3541, "1h"), (3599, "1h"), (3600, "1h"), (3660, "1h 1m"),
                            (86399, "1d"), (86400, "1d"), (291600, "3d 9h")] {
    check("\(Int(seconds))s", resetsInText(seconds), expected)
}

// ---------------------------------------------------------------------------
print("  limitBarColor")
for (percent, expected) in [(0.0, "controlAccentColor"), (79.9, "controlAccentColor"),
                            (80.0, "systemOrange"), (94.9, "systemOrange"),
                            (95.0, "systemRed"), (100.0, "systemRed")] {
    let colour = limitBarColor(percent)
    let name: String
    if colour == NSColor.systemRed { name = "systemRed" }
    else if colour == NSColor.systemOrange { name = "systemOrange" }
    else { name = "controlAccentColor" }
    check("\(percent)%", name, expected)
}

// ---------------------------------------------------------------------------
print("  limitPlaceholder")
let clock = Date().timeIntervalSince1970
func placeholder(_ json: String, live: Bool) -> String {
    guard let file = try? decoder.decode(LimitsFile.self, from: json.data(using: .utf8)!)
    else { return "DECODE FAILED" }
    return limitPlaceholder(file, now: clock, sessionsLive: live).text
}
check("no reading yet",
      placeholder(#"{"seen_at":\#(clock),"rate_limits_seen":false,"windows":{}}"#, live: true),
      "no reading yet")
// Six minutes at a prompt without sending anything used to be reported as
// "not available on this account", to a subscriber.
check("idle at a prompt is still 'no reading yet'",
      placeholder(#"{"seen_at":\#(clock),"first_seen_at":\#(clock - 400),"rate_limits_seen":false,"windows":{}}"#, live: true),
      "no reading yet")
check("window reset",
      placeholder(#"{"seen_at":\#(clock),"rate_limits_seen":true,"windows":{}}"#, live: true),
      "window reset")
check("stalled while sessions are open",
      placeholder(#"{"seen_at":\#(clock - 3600),"rate_limits_seen":true,"windows":{}}"#, live: true),
      "not updating")
check("stalled with nothing running",
      placeholder(#"{"seen_at":\#(clock - 3600),"rate_limits_seen":true,"windows":{}}"#, live: false),
      "no Claude Code session running")

// ---------------------------------------------------------------------------
print("  modelLimitRows")
func isoStamp(_ offset: Double) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    // Microseconds, exactly as the server sends them.
    return f.string(from: Date(timeIntervalSince1970: clock + offset))
        .replacingOccurrences(of: "Z", with: ".626909+00:00")
}
func rows(_ json: String) -> String {
    guard let cache = try? decoder.decode(ClaudeConfigFile.self, from: json.data(using: .utf8)!)
        .cachedUsageUtilization else { return "NO CACHE" }
    let rows = modelLimitRows(cache, now: clock)
    if rows.isEmpty { return "(none)" }
    return rows.map { "\($0.label) \($0.percentText)" }.joined(separator: ", ")
}
let fresh = (clock - 300) * 1000
// A model that has not been used has no window: 0% with a null reset time, and
// a bar sitting at zero forever is worse than no row.
check("never used", rows(#"""
{"cachedUsageUtilization":{"fetchedAtMs":\#(fresh),"utilization":{"limits":
 [{"kind":"weekly_scoped","percent":0,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}}]}}}
"""#), "(none)")
check("in use", rows(#"""
{"cachedUsageUtilization":{"fetchedAtMs":\#(fresh),"utilization":{"limits":
 [{"kind":"weekly_scoped","percent":37.5,"resets_at":"\#(isoStamp(200000))","scope":{"model":{"display_name":"Fable"}}}]}}}
"""#), "Fable (7d) 38%")
// The server-named row wins over the fixed key for the same model.
check("limits[] beats seven_day_opus", rows(#"""
{"cachedUsageUtilization":{"fetchedAtMs":\#(fresh),"utilization":{
 "seven_day_opus":{"utilization":88,"resets_at":"\#(isoStamp(150000))"},
 "limits":[{"kind":"weekly_scoped","percent":12,"resets_at":"\#(isoStamp(200000))","scope":{"model":{"display_name":"Opus"}}},
           {"kind":"other","percent":99,"resets_at":"\#(isoStamp(9999))","scope":{"model":{"display_name":"Ignored"}}}]}}}
"""#), "Opus (7d) 12%")
check("cache older than a day", rows(#"""
{"cachedUsageUtilization":{"fetchedAtMs":\#((clock - 90000) * 1000),"utilization":{"limits":
 [{"kind":"weekly_scoped","percent":37.5,"resets_at":"\#(isoStamp(200000))","scope":{"model":{"display_name":"Fable"}}}]}}}
"""#), "(none)")
check("no cache key", rows(#"{"other":1}"#), "NO CACHE")

// ---------------------------------------------------------------------------
// The seam that matters most: what the hook actually wrote, decoded by the app.
if CommandLine.arguments.count > 1 {
    print("  limits.json written by the hook")
    let path = CommandLine.arguments[1]
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let file = try? decoder.decode(LimitsFile.self, from: data) else {
        print("    FAIL could not decode \(path)")
        failures += 1
        exit(1)
    }
    check("rateLimitsSeen decoded", "\(file.rateLimitsSeen ?? false)", "true")
    check("seenAt decoded", "\(file.seenAt != nil)", "true")
    for kind in LimitKind.allCases {
        guard let window = kind.window(file) else {
            print("    FAIL \(kind.label) missing"); failures += 1; continue
        }
        check("\(kind.label) live", "\(window.isLive(clock))", "true")
        check("\(kind.label) capturedAt", "\(window.capturedAt != nil)", "true")
        check("\(kind.label) percent in range",
              "\(window.percent >= 0 && window.percent <= 100)", "true")
    }
}

print(failures == 0 ? "  all Swift assertions passed" : "  \(failures) Swift assertion(s) FAILED")
exit(failures == 0 ? 0 : 1)
