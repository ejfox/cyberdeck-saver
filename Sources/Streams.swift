import AppKit
import Foundation

struct FormattedLine {
    let text: String
    let color: NSColor
}

protocol DataStream {
    var name: String { get }
    func fetch(completion: @escaping ([FormattedLine]) -> Void)
}

// MARK: - Vulpes Colors

enum Vulpes {
    static let hotPink      = NSColor(red: 0.902, green: 0.000, blue: 0.404, alpha: 1)
    static let teal         = NSColor(red: 0.431, green: 0.929, blue: 0.969, alpha: 1)
    static let lightPink    = NSColor(red: 0.949, green: 0.812, blue: 0.875, alpha: 1)
    static let mutedMagenta = NSColor(red: 0.451, green: 0.149, blue: 0.290, alpha: 1)
    static let muted        = NSColor(red: 0.451, green: 0.345, blue: 0.396, alpha: 1)
    static let dimPink      = NSColor(red: 0.600, green: 0.300, blue: 0.420, alpha: 1)
    static let dimTeal      = NSColor(red: 0.250, green: 0.500, blue: 0.520, alpha: 1)
    static let orange       = NSColor(red: 0.900, green: 0.400, blue: 0.100, alpha: 1)
    static let green        = NSColor(red: 0.200, green: 0.750, blue: 0.350, alpha: 1)
}

// MARK: - Helpers

private func fetchJSON(from urlString: String, timeout: TimeInterval = 10, completion: @escaping (Any?) -> Void) {
    guard let url = URL(string: urlString) else { completion(nil); return }
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    URLSession.shared.dataTask(with: req) { data, _, _ in
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) else {
            completion(nil); return
        }
        completion(json)
    }.resume()
}

private func val(_ dict: Any?, _ key: String) -> String {
    guard let d = dict as? [String: Any], let v = d[key] else { return "\u{2014}" }
    return "\(v)"
}

private func bar(_ pct: Double, width: Int = 10) -> String {
    let clamped = max(0, min(100, pct))
    let filled = Int(clamped / 100.0 * Double(width))
    let empty = width - filled
    return String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: empty)
}

func wrapText(_ text: String, width: Int) -> [String] {
    guard !text.isEmpty else { return [] }
    var result: [String] = []
    var current = ""
    for word in text.split(separator: " ") {
        if current.count + word.count + 1 > width {
            if !current.isEmpty { result.append(current) }
            current = String(word)
        } else {
            current += (current.isEmpty ? "" : " ") + word
        }
    }
    if !current.isEmpty { result.append(current) }
    return result
}

// =========================================================================
// REAL SYSTEM DATA
// =========================================================================

class CommandStream: DataStream {
    let name = "CMD"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let time = df.string(from: Date())
        df.dateFormat = "yyyy-MM-dd  EEEE"
        let date = df.string(from: Date())
        let up = ProcessInfo.processInfo.systemUptime
        let h = Int(up) / 3600; let m = (Int(up) % 3600) / 60

        completion([
            FormattedLine(text: "CYBERDECK v1.0", color: Vulpes.hotPink),
            FormattedLine(text: "STATUS: OPERATIONAL", color: Vulpes.green),
            FormattedLine(text: "", color: Vulpes.muted),
            FormattedLine(text: time, color: Vulpes.teal),
            FormattedLine(text: date, color: Vulpes.lightPink),
            FormattedLine(text: "", color: Vulpes.muted),
            FormattedLine(text: "UPTIME \(h)h \(m)m", color: Vulpes.dimPink),
        ])
    }
}

class SystemStream: DataStream {
    let name = "SYSINFO"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        let host = Host.current().localizedName ?? "UNKNOWN"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let mem = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        let thermal = ProcessInfo.processInfo.thermalState
        let tStr: String; let tColor: NSColor
        switch thermal {
        case .nominal: tStr = "NOMINAL"; tColor = Vulpes.green
        case .fair: tStr = "FAIR"; tColor = Vulpes.dimTeal
        case .serious: tStr = "ELEVATED"; tColor = Vulpes.orange
        case .critical: tStr = "CRITICAL"; tColor = Vulpes.hotPink
        @unknown default: tStr = "?"; tColor = Vulpes.muted
        }
        var lines: [FormattedLine] = [
            FormattedLine(text: "HOST    \(host.uppercased())", color: Vulpes.teal),
            FormattedLine(text: "DARWIN  \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", color: Vulpes.lightPink),
        ]
        #if arch(arm64)
        lines.append(FormattedLine(text: "ARCH    ARM64", color: Vulpes.lightPink))
        #else
        lines.append(FormattedLine(text: "ARCH    X86_64", color: Vulpes.lightPink))
        #endif
        lines += [
            FormattedLine(text: "CPU     \(cores) CORES", color: Vulpes.dimPink),
            FormattedLine(text: "MEM     \(mem) GB", color: Vulpes.dimPink),
            FormattedLine(text: "THERMAL \(tStr)", color: tColor),
        ]
        completion(lines)
    }
}

// =========================================================================
// PERSONAL APIs (actual response shapes verified)
// =========================================================================

// /api/stats is the mega-endpoint — has github, health, chess, monkeytype, rescuetime, lastfm all in one
// Use it as fallback/primary for several panels

class GitHubStream: DataStream {
    let name = "SIGINT"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        fetchJSON(from: "https://ejfox.com/api/stats") { json in
            var lines: [FormattedLine] = []
            let gh = (json as? [String: Any])?["github"] as? [String: Any]
            let stats = gh?["stats"] as? [String: Any]

            lines.append(FormattedLine(text: "TARGET: github.com/ejfox", color: Vulpes.teal))
            if let s = stats {
                lines.append(FormattedLine(text: "FEED: LIVE \u{25CF}", color: Vulpes.green))
                lines.append(FormattedLine(text: "COMMITS     \(val(s, "totalCommits"))", color: Vulpes.lightPink))
                lines.append(FormattedLine(text: "REPOS       \(val(s, "totalRepos"))", color: Vulpes.dimPink))
                lines.append(FormattedLine(text: "FOLLOWERS   \(val(s, "followers"))", color: Vulpes.dimPink))
                lines.append(FormattedLine(text: "FOLLOWING   \(val(s, "following"))", color: Vulpes.muted))
            }
            if let recent = gh?["recentActivity"] as? [[String: Any]] {
                lines.append(FormattedLine(text: "", color: Vulpes.muted))
                lines.append(FormattedLine(text: "RECENT", color: Vulpes.hotPink))
                for event in recent.prefix(4) {
                    let repo = val(event, "repo")
                    let type = (event["type"] as? String ?? "").replacingOccurrences(of: "Event", with: "")
                    lines.append(FormattedLine(text: "  \(type) \(repo)", color: Vulpes.dimPink))
                }
            }
            if lines.isEmpty { lines.append(FormattedLine(text: "ACQUIRING...", color: Vulpes.muted)) }
            completion(lines)
        }
    }
}

class MusicStream: DataStream {
    let name = "ACINT"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        fetchJSON(from: "https://ejfox.com/api/lastfm") { json in
            var lines: [FormattedLine] = []
            let d = json as? [String: Any]

            lines.append(FormattedLine(text: "AUDIO FEED: \(d != nil ? "ACTIVE \u{25CF}" : "SCANNING")", color: d != nil ? Vulpes.green : Vulpes.orange))

            // recentTracks.tracks is the array
            if let rt = d?["recentTracks"] as? [String: Any],
               let tracks = rt["tracks"] as? [[String: Any]] {
                if let first = tracks.first {
                    let name = val(first, "name")
                    let artist = (first["artist"] as? [String: Any])?["name"] as? String ?? "?"
                    lines.append(FormattedLine(text: "", color: Vulpes.muted))
                    lines.append(FormattedLine(text: "LATEST", color: Vulpes.hotPink))
                    lines.append(FormattedLine(text: "  \(name)", color: Vulpes.lightPink))
                    lines.append(FormattedLine(text: "  \(artist)", color: Vulpes.teal))
                }
                lines.append(FormattedLine(text: "", color: Vulpes.muted))
                lines.append(FormattedLine(text: "HISTORY", color: Vulpes.mutedMagenta))
                for track in tracks.dropFirst().prefix(4) {
                    let name = val(track, "name")
                    let artist = (track["artist"] as? [String: Any])?["name"] as? String ?? "?"
                    lines.append(FormattedLine(text: "  \(artist) / \(name)", color: Vulpes.muted))
                }
            }
            if let ui = d?["userInfo"] as? [String: Any], let pc = ui["playcount"] {
                lines.append(FormattedLine(text: "", color: Vulpes.muted))
                lines.append(FormattedLine(text: "SCROBBLES: \(pc)", color: Vulpes.dimPink))
            }
            if lines.count <= 1 { lines.append(FormattedLine(text: "SCANNING...", color: Vulpes.muted)) }
            completion(lines)
        }
    }
}

class HealthStream: DataStream {
    let name = "BIOMETRIC"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        // Health API is down, use /api/stats which has health.today
        fetchJSON(from: "https://ejfox.com/api/stats") { json in
            var lines: [FormattedLine] = []
            let d = (json as? [String: Any])
            let health = d?["health"] as? [String: Any]
            let today = health?["today"] as? [String: Any]

            lines.append(FormattedLine(text: "OPERATOR: \(today != nil ? "NOMINAL" : "NO DATA")", color: today != nil ? Vulpes.green : Vulpes.orange))
            if let t = today {
                if let s = t["steps"] as? Int {
                    lines.append(FormattedLine(text: "STEPS     \(s) \(bar(Double(s)/100.0))", color: Vulpes.teal))
                }
                if let e = t["exerciseMinutes"] as? Int {
                    lines.append(FormattedLine(text: "EXERCISE  \(e) min \(bar(Double(e)/0.3))", color: Vulpes.lightPink))
                }
                if let s = t["standHours"] as? Int {
                    lines.append(FormattedLine(text: "STAND     \(s)/12 hr \(bar(Double(s)/0.12))", color: Vulpes.lightPink))
                }
                if let d = t["distance"] {
                    lines.append(FormattedLine(text: "DISTANCE  \(d) mi", color: Vulpes.dimPink))
                }
            }
            if lines.count <= 1 { lines.append(FormattedLine(text: "AWAITING TELEMETRY...", color: Vulpes.muted)) }
            completion(lines)
        }
    }
}

class ChessStream: DataStream {
    let name = "GAMEINT"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        fetchJSON(from: "https://ejfox.com/api/chess") { json in
            var lines: [FormattedLine] = [
                FormattedLine(text: "STRATEGIC ANALYSIS", color: Vulpes.teal),
            ]
            let d = json as? [String: Any]
            if let cr = d?["currentRating"] as? [String: Any] {
                if let r = cr["rapid"] as? Int { lines.append(FormattedLine(text: "RAPID   \(r) \(bar(Double(r-200)/15.0))", color: Vulpes.lightPink)) }
                if let b = cr["blitz"] as? Int { lines.append(FormattedLine(text: "BLITZ   \(b)", color: Vulpes.dimPink)) }
                if let bu = cr["bullet"] as? Int { lines.append(FormattedLine(text: "BULLET  \(bu)", color: Vulpes.dimPink)) }
            }
            if let gp = d?["gamesPlayed"] as? [String: Any], let t = gp["total"] {
                lines.append(FormattedLine(text: "GAMES   \(t)", color: Vulpes.muted))
            }
            if let wr = d?["winRate"] as? [String: Any], let o = wr["overall"] as? Double {
                lines.append(FormattedLine(text: "WINRATE \(String(format: "%.0f", o))% \(bar(o))", color: Vulpes.dimPink))
            }
            if lines.count <= 1 { lines.append(FormattedLine(text: "LOADING...", color: Vulpes.muted)) }
            completion(lines)
        }
    }
}

class TypingStream: DataStream {
    let name = "KEYINT"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        fetchJSON(from: "https://ejfox.com/api/monkeytype") { json in
            var lines: [FormattedLine] = [
                FormattedLine(text: "KEYSTROKE ANALYSIS", color: Vulpes.teal),
            ]
            let ts = (json as? [String: Any])?["typingStats"] as? [String: Any]
            if let w = ts?["bestWPM"] as? Double {
                lines.append(FormattedLine(text: "BEST WPM  \(String(format: "%.0f", w)) \(bar(min(100,w/1.5)))", color: Vulpes.hotPink))
            }
            if let a = ts?["bestAccuracy"] as? Double {
                lines.append(FormattedLine(text: "ACCURACY  \(String(format: "%.0f", a))%", color: Vulpes.lightPink))
            }
            if let t = ts?["testsCompleted"] as? Int {
                lines.append(FormattedLine(text: "TESTS     \(t)", color: Vulpes.dimPink))
            }
            if let c = ts?["bestConsistency"] as? Double {
                lines.append(FormattedLine(text: "CONSIST.  \(String(format: "%.0f", c))%", color: Vulpes.dimPink))
            }
            if lines.count <= 1 { lines.append(FormattedLine(text: "CALIBRATING...", color: Vulpes.muted)) }
            completion(lines)
        }
    }
}

class RescueTimeStream: DataStream {
    let name = "PRODINT"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        fetchJSON(from: "https://ejfox.com/api/rescuetime") { json in
            var lines: [FormattedLine] = [
                FormattedLine(text: "PRODUCTIVITY INTEL", color: Vulpes.teal),
            ]
            let d = json as? [String: Any]
            if let week = d?["week"] as? [String: Any],
               let cats = week["categories"] as? [[String: Any]] {
                for cat in cats.prefix(6) {
                    let name = (cat["name"] as? String ?? "?").prefix(18)
                    let time = cat["time"] as? [String: Any]
                    let hrs = time?["hours"] as? Double ?? (Double(time?["seconds"] as? Int ?? 0) / 3600)
                    lines.append(FormattedLine(text: "  \(name)", color: Vulpes.lightPink))
                    lines.append(FormattedLine(text: "    \(String(format: "%.1f", hrs))h", color: Vulpes.dimPink))
                }
            }
            if lines.count <= 1 { lines.append(FormattedLine(text: "MONITORING...", color: Vulpes.muted)) }
            completion(lines)
        }
    }
}

class StatsStream: DataStream {
    let name = "METRICS"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        fetchJSON(from: "https://ejfox.com/api/stats") { json in
            var lines: [FormattedLine] = [
                FormattedLine(text: "WEEKLY SUMMARY", color: Vulpes.teal),
            ]
            let d = json as? [String: Any]
            if let ws = d?["weeklySummary"] as? [String: Any] {
                if let ph = ws["productiveHours"] as? Double {
                    lines.append(FormattedLine(text: "PRODUCTIVE  \(String(format:"%.1f",ph))h", color: Vulpes.lightPink))
                }
                if let th = ws["totalTrackedHours"] as? Double {
                    lines.append(FormattedLine(text: "TRACKED     \(String(format:"%.1f",th))h", color: Vulpes.dimPink))
                }
                if let pp = ws["productivityPercent"] as? Double {
                    lines.append(FormattedLine(text: "EFFICIENCY  \(String(format:"%.0f",pp))% \(bar(pp))", color: Vulpes.dimPink))
                }
            }
            if let lf = d?["lastfm"] as? [String: Any] {
                if let sc = lf["scrobbles"] { lines.append(FormattedLine(text: "SCROBBLES   \(sc)", color: Vulpes.muted)) }
            }
            if let lt = d?["letterboxd"] as? [String: Any] {
                if let f = lt["films"] { lines.append(FormattedLine(text: "FILMS       \(f)", color: Vulpes.muted)) }
            }
            if lines.count <= 1 { lines.append(FormattedLine(text: "COMPILING...", color: Vulpes.muted)) }
            completion(lines)
        }
    }
}

class WordsStream: DataStream {
    let name = "OSINT-W"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        fetchJSON(from: "https://ejfox.com/api/words-this-month") { json in
            var lines: [FormattedLine] = [
                FormattedLine(text: "WRITTEN INTEL", color: Vulpes.teal),
            ]
            let d = json as? [String: Any]
            if let m = d?["month"], let y = d?["year"] {
                lines.append(FormattedLine(text: "\(m) \(y)", color: Vulpes.lightPink))
            }
            if let w = d?["totalWords"] { lines.append(FormattedLine(text: "WORDS  \(w)", color: Vulpes.dimPink)) }
            if let p = d?["postCount"] { lines.append(FormattedLine(text: "POSTS  \(p)", color: Vulpes.dimPink)) }
            if let a = d?["avgWordsPerPost"] { lines.append(FormattedLine(text: "AVG    \(a) per post", color: Vulpes.muted)) }
            if lines.count <= 1 { lines.append(FormattedLine(text: "COUNTING...", color: Vulpes.muted)) }
            completion(lines)
        }
    }
}

class LeetCodeStream: DataStream {
    let name = "CODEINT"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        fetchJSON(from: "https://ejfox.com/api/leetcode") { json in
            var lines: [FormattedLine] = [
                FormattedLine(text: "CODE ANALYSIS", color: Vulpes.teal),
            ]
            let d = json as? [String: Any]
            if let ss = d?["submissionStats"] as? [String: Any] {
                for diff in ["easy", "medium", "hard"] {
                    if let s = ss[diff] as? [String: Any], let c = s["count"] {
                        lines.append(FormattedLine(text: "\(diff.uppercased().padding(toLength: 8, withPad: " ", startingAt: 0)) \(c) solved", color: diff == "hard" ? Vulpes.hotPink : Vulpes.lightPink))
                    }
                }
            }
            if let recent = d?["recentSubmissions"] as? [[String: Any]] {
                lines.append(FormattedLine(text: "", color: Vulpes.muted))
                lines.append(FormattedLine(text: "RECENT", color: Vulpes.mutedMagenta))
                for sub in recent.prefix(3) {
                    let title = (sub["title"] as? String ?? "?").prefix(30)
                    lines.append(FormattedLine(text: "  \(title)", color: Vulpes.dimPink))
                }
            }
            if lines.count <= 1 { lines.append(FormattedLine(text: "ANALYZING...", color: Vulpes.muted)) }
            completion(lines)
        }
    }
}

class MastodonStream: DataStream {
    let name = "COMINT"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        // Mastodon API times out, use lastfm stats endpoint which is more reliable
        // Or just show a status message
        fetchJSON(from: "https://mastodon-posts.ejfox.tools/", timeout: 15) { json in
            var lines: [FormattedLine] = []
            if let posts = json as? [[String: Any]] {
                lines.append(FormattedLine(text: "FEDIVERSE: LIVE \u{25CF}", color: Vulpes.green))
                lines.append(FormattedLine(text: "@ejfox@mastodon.social", color: Vulpes.dimTeal))
                for post in posts.prefix(2) {
                    let content = (post["content"] as? String ?? "")
                        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let date = String((post["created_at"] as? String ?? "").prefix(10))
                    lines.append(FormattedLine(text: "", color: Vulpes.muted))
                    lines.append(FormattedLine(text: date, color: Vulpes.mutedMagenta))
                    for chunk in wrapText(content, width: 34).prefix(3) {
                        lines.append(FormattedLine(text: "  \(chunk)", color: Vulpes.lightPink))
                    }
                }
            } else {
                lines.append(FormattedLine(text: "FEDIVERSE: TIMEOUT", color: Vulpes.orange))
                lines.append(FormattedLine(text: "Retrying...", color: Vulpes.muted))
            }
            completion(lines)
        }
    }
}

// =========================================================================
// VPS OSINT FEEDS (real operational intelligence)
// These APIs are slow (~10-15s) — use long timeouts, no nested fetches
// =========================================================================

class SkywatchStream: DataStream {
    let name = "SKYWATCH"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        fetchJSON(from: "https://skywatch.tools.ejfox.com/api/stats", timeout: 20) { json in
            var lines: [FormattedLine] = []
            let d = json as? [String: Any]

            lines.append(FormattedLine(text: "AIRSPACE SURVEILLANCE", color: Vulpes.teal))
            lines.append(FormattedLine(text: "HUDSON VALLEY AOR", color: Vulpes.dimTeal))
            lines.append(FormattedLine(text: "", color: Vulpes.muted))

            if let d = d {
                lines.append(FormattedLine(text: "TODAY     \(d["today"] ?? "?") flights", color: Vulpes.lightPink))
                lines.append(FormattedLine(text: "MILITARY  \(d["military"] ?? "?") tracked", color: Vulpes.hotPink))
                lines.append(FormattedLine(text: "TOTAL DB  \(d["total"] ?? "?")", color: Vulpes.dimPink))
            } else {
                lines.append(FormattedLine(text: "FEED: CONNECTING...", color: Vulpes.orange))
                lines.append(FormattedLine(text: "VPS may be slow", color: Vulpes.muted))
            }
            completion(lines)
        }
    }
}

class AnomalywatchStream: DataStream {
    let name = "ANOMALY"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        fetchJSON(from: "https://anomalywatch.tools.ejfox.com/api/stats", timeout: 20) { json in
            var lines: [FormattedLine] = []
            let d = json as? [String: Any]

            lines.append(FormattedLine(text: "ANOMALY DETECTION", color: Vulpes.teal))
            lines.append(FormattedLine(text: "", color: Vulpes.muted))

            if let d = d {
                lines.append(FormattedLine(text: "SIGNALS      \(d["signals"] ?? "?")", color: Vulpes.lightPink))
                lines.append(FormattedLine(text: "ALERTS       \(d["incoming_alerts"] ?? "?")", color: Vulpes.dimPink))
                lines.append(FormattedLine(text: "ACTIVE CASES \(d["active_investigations"] ?? "?")", color: Vulpes.hotPink))
            } else {
                lines.append(FormattedLine(text: "FEED: CONNECTING...", color: Vulpes.orange))
            }
            completion(lines)
        }
    }
}

class BriefingsStream: DataStream {
    let name = "BRIEFING"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        fetchJSON(from: "https://briefings.tools.ejfox.com/api/reports", timeout: 20) { json in
            var lines: [FormattedLine] = [
                FormattedLine(text: "DAILY INTELLIGENCE", color: Vulpes.teal),
                FormattedLine(text: "", color: Vulpes.muted),
            ]
            if let reports = json as? [[String: Any]] {
                for report in reports.prefix(5) {
                    let date = String((report["date"] as? String ?? "").prefix(10))
                    let title = report["title"] as? String ?? "Untitled"
                    lines.append(FormattedLine(text: date, color: Vulpes.mutedMagenta))
                    for chunk in wrapText(title, width: 34).prefix(2) {
                        lines.append(FormattedLine(text: "  \(chunk)", color: Vulpes.lightPink))
                    }
                }
            } else {
                lines.append(FormattedLine(text: "AWAITING BRIEFING...", color: Vulpes.muted))
            }
            completion(lines)
        }
    }
}

class OverwatchStream: DataStream {
    let name = "OVERWATCH"
    func fetch(completion: @escaping ([FormattedLine]) -> Void) {
        fetchJSON(from: "https://overwatch.tools.ejfox.com/api/stats", timeout: 20) { json in
            var lines: [FormattedLine] = [
                FormattedLine(text: "FACILITY MONITORING", color: Vulpes.teal),
                FormattedLine(text: "", color: Vulpes.muted),
            ]
            if let d = json as? [String: Any] {
                for (key, value) in d.sorted(by: { $0.key < $1.key }).prefix(6) {
                    let label = key.uppercased().padding(toLength: 12, withPad: " ", startingAt: 0)
                    lines.append(FormattedLine(text: "\(label) \(value)", color: Vulpes.lightPink))
                }
            } else {
                lines.append(FormattedLine(text: "FEED: CONNECTING...", color: Vulpes.orange))
            }
            completion(lines)
        }
    }
}
