import AppKit
import Foundation

// MARK: - GitHub activity

class GitHubStream: DataStream {
    let name = "github"
    let url: String
    init(url: String) { self.url = url }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("github.com/ejfox", Vulpes.teal),
            FormattedLine("commits     4823", Vulpes.lightPink),
            FormattedLine("repos       142", Vulpes.dimPink),
            FormattedLine("followers   89", Vulpes.dimPink),
            FormattedLine("following   31", Vulpes.muted),
            FormattedLine("", Vulpes.muted),
            FormattedLine("recent", Vulpes.mutedMagenta),
            FormattedLine("  push ejfox/website", Vulpes.dimPink),
            FormattedLine("  pullrequest ejfox/cyber", Vulpes.dimPink),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(url: url, header: "github.com/ejfox", build: { json in
            var lines: [FormattedLine] = []
            let gh = (json as? [String: Any])?["github"] as? [String: Any]
            if let s = gh?["stats"] as? [String: Any] {
                lines.append(FormattedLine("commits     \(str(s, "totalCommits"))", Vulpes.lightPink))
                lines.append(FormattedLine("repos       \(str(s, "totalRepos"))", Vulpes.dimPink))
                lines.append(FormattedLine("followers   \(str(s, "followers"))", Vulpes.dimPink))
                lines.append(FormattedLine("following   \(str(s, "following"))", Vulpes.muted))
            }
            if let recent = gh?["recentActivity"] as? [[String: Any]] {
                lines.append(FormattedLine("", Vulpes.muted))
                lines.append(FormattedLine("recent", Vulpes.mutedMagenta))
                for event in recent.prefix(4) {
                    let repo = str(event, "repo")
                    let type = (event["type"] as? String ?? "").replacingOccurrences(of: "Event", with: "")
                    lines.append(FormattedLine("  \(type.lowercased()) \(repo)", Vulpes.dimPink))
                }
            }
            return lines
        }, completion: completion)
    }
}

// MARK: - Last.fm music

class MusicStream: DataStream {
    let name = "last.fm"
    let url: String
    init(url: String) { self.url = url }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("last.fm/ejfox", Vulpes.teal),
            FormattedLine("", Vulpes.muted),
            FormattedLine("now playing", Vulpes.hotPink),
            FormattedLine("  Roygbiv", Vulpes.lightPink),
            FormattedLine("  Boards of Canada", Vulpes.teal),
            FormattedLine("", Vulpes.muted),
            FormattedLine("recent", Vulpes.mutedMagenta),
            FormattedLine("  Aphex Twin / Xtal", Vulpes.muted),
            FormattedLine("  Four Tet / Angel Echoes", Vulpes.muted),
            FormattedLine("", Vulpes.muted),
            FormattedLine("scrobbles  147823", Vulpes.dimPink),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(url: url, header: "last.fm/ejfox", build: { json in
            var lines: [FormattedLine] = []
            let d = json as? [String: Any]
            if let rt = d?["recentTracks"] as? [String: Any],
               let tracks = rt["tracks"] as? [[String: Any]] {
                if let first = tracks.first {
                    let name = str(first, "name")
                    let artist = (first["artist"] as? [String: Any])?["name"] as? String ?? "?"
                    lines.append(FormattedLine("", Vulpes.muted))
                    lines.append(FormattedLine("now playing", Vulpes.hotPink))
                    lines.append(FormattedLine("  \(name)", Vulpes.lightPink))
                    lines.append(FormattedLine("  \(artist)", Vulpes.teal))
                }
                if tracks.count > 1 {
                    lines.append(FormattedLine("", Vulpes.muted))
                    lines.append(FormattedLine("recent", Vulpes.mutedMagenta))
                    for track in tracks.dropFirst().prefix(4) {
                        let name = str(track, "name")
                        let artist = (track["artist"] as? [String: Any])?["name"] as? String ?? "?"
                        lines.append(FormattedLine("  \(artist) / \(name)", Vulpes.muted))
                    }
                }
            }
            if let ui = d?["userInfo"] as? [String: Any], let pc = ui["playcount"] {
                lines.append(FormattedLine("", Vulpes.muted))
                lines.append(FormattedLine("scrobbles  \(pc)", Vulpes.dimPink))
            }
            return lines
        }, completion: completion)
    }
}

// MARK: - Apple Health

class HealthStream: DataStream {
    let name = "health"
    let url: String
    init(url: String) { self.url = url }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("today", Vulpes.teal),
            FormattedLine("steps     8234 \(bar(8234, max: 10_000))", Vulpes.teal),
            FormattedLine("exercise  22m \(bar(22, max: 30))", Vulpes.lightPink),
            FormattedLine("stand     9/12h \(bar(9, max: 12))", Vulpes.lightPink),
            FormattedLine("distance  3.4 mi", Vulpes.dimPink),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(url: url, header: "today", build: { json in
            var lines: [FormattedLine] = []
            let health = (json as? [String: Any])?["health"] as? [String: Any]
            let today = health?["today"] as? [String: Any]
            if let t = today {
                if let s = t["steps"] as? Int {
                    lines.append(FormattedLine("steps     \(s) \(bar(Double(s), max: 10_000))", Vulpes.teal))
                }
                if let e = t["exerciseMinutes"] as? Int {
                    lines.append(FormattedLine("exercise  \(e)m \(bar(Double(e), max: 30))", Vulpes.lightPink))
                }
                if let s = t["standHours"] as? Int {
                    lines.append(FormattedLine("stand     \(s)/12h \(bar(Double(s), max: 12))", Vulpes.lightPink))
                }
                if let d = t["distance"] {
                    lines.append(FormattedLine("distance  \(d) mi", Vulpes.dimPink))
                }
            } else {
                lines.append(FormattedLine("no data", Vulpes.muted))
            }
            return lines
        }, completion: completion)
    }
}

// MARK: - Chess.com ratings

class ChessStream: DataStream {
    let name = "chess"
    let url: String
    init(url: String) { self.url = url }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("chess.com ratings", Vulpes.teal),
            FormattedLine("rapid   1247 \(bar(1047, max: 1500))", Vulpes.lightPink),
            FormattedLine("blitz   1180", Vulpes.dimPink),
            FormattedLine("bullet  1050", Vulpes.dimPink),
            FormattedLine("games   847", Vulpes.muted),
            FormattedLine("winrate 54% \(bar(54, max: 100))", Vulpes.dimPink),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(url: url, header: "chess.com ratings", build: { json in
            var lines: [FormattedLine] = []
            let d = json as? [String: Any]
            if let cr = d?["currentRating"] as? [String: Any] {
                if let r = cr["rapid"] as? Int {
                    lines.append(FormattedLine("rapid   \(r) \(bar(Double(r - 200), max: 1500))", Vulpes.lightPink))
                }
                if let b = cr["blitz"] as? Int {
                    lines.append(FormattedLine("blitz   \(b)", Vulpes.dimPink))
                }
                if let bu = cr["bullet"] as? Int {
                    lines.append(FormattedLine("bullet  \(bu)", Vulpes.dimPink))
                }
            }
            if let gp = d?["gamesPlayed"] as? [String: Any], let t = gp["total"] {
                lines.append(FormattedLine("games   \(t)", Vulpes.muted))
            }
            if let wr = d?["winRate"] as? [String: Any], let o = wr["overall"] as? Double {
                lines.append(FormattedLine("winrate \(String(format: "%.0f", o))% \(bar(o, max: 100))", Vulpes.dimPink))
            }
            return lines
        }, completion: completion)
    }
}

// MARK: - MonkeyType

class TypingStream: DataStream {
    let name = "monkeytype"
    let url: String
    init(url: String) { self.url = url }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("monkeytype", Vulpes.teal),
            FormattedLine("best wpm  92 \(bar(92, max: 150))", Vulpes.hotPink),
            FormattedLine("accuracy  96%", Vulpes.lightPink),
            FormattedLine("tests     342", Vulpes.dimPink),
            FormattedLine("consist.  87%", Vulpes.dimPink),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(url: url, header: "monkeytype", build: { json in
            var lines: [FormattedLine] = []
            let ts = (json as? [String: Any])?["typingStats"] as? [String: Any]
            if let w = ts?["bestWPM"] as? Double {
                lines.append(FormattedLine("best wpm  \(String(format: "%.0f", w)) \(bar(w, max: 150))", Vulpes.hotPink))
            }
            if let a = ts?["bestAccuracy"] as? Double {
                lines.append(FormattedLine("accuracy  \(String(format: "%.0f", a))%", Vulpes.lightPink))
            }
            if let t = ts?["testsCompleted"] as? Int {
                lines.append(FormattedLine("tests     \(t)", Vulpes.dimPink))
            }
            if let c = ts?["bestConsistency"] as? Double {
                lines.append(FormattedLine("consist.  \(String(format: "%.0f", c))%", Vulpes.dimPink))
            }
            return lines
        }, completion: completion)
    }
}

// MARK: - RescueTime

class RescueTimeStream: DataStream {
    let name = "rescuetime"
    let url: String
    init(url: String) { self.url = url }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("this week", Vulpes.teal),
            FormattedLine("  software dev", Vulpes.lightPink),
            FormattedLine("    18.4h", Vulpes.dimPink),
            FormattedLine("  communication", Vulpes.lightPink),
            FormattedLine("    6.2h", Vulpes.dimPink),
            FormattedLine("  reference", Vulpes.lightPink),
            FormattedLine("    3.7h", Vulpes.dimPink),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(url: url, header: "this week", build: { json in
            var lines: [FormattedLine] = []
            let d = json as? [String: Any]
            if let week = d?["week"] as? [String: Any],
               let cats = week["categories"] as? [[String: Any]] {
                for cat in cats.prefix(6) {
                    let name = (cat["name"] as? String ?? "?").prefix(18)
                    let time = cat["time"] as? [String: Any]
                    let hrs = time?["hours"] as? Double ?? (Double(time?["seconds"] as? Int ?? 0) / 3600)
                    lines.append(FormattedLine("  \(name.lowercased())", Vulpes.lightPink))
                    lines.append(FormattedLine("    \(String(format: "%.1f", hrs))h", Vulpes.dimPink))
                }
            } else {
                lines.append(FormattedLine("no data", Vulpes.muted))
            }
            return lines
        }, completion: completion)
    }
}

// MARK: - Weekly aggregate

class StatsStream: DataStream {
    let name = "stats"
    let url: String
    init(url: String) { self.url = url }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("weekly", Vulpes.teal),
            FormattedLine("productive  28.3h", Vulpes.lightPink),
            FormattedLine("tracked     41.2h", Vulpes.dimPink),
            FormattedLine("efficiency  68% \(bar(68, max: 100))", Vulpes.dimPink),
            FormattedLine("scrobbles   842", Vulpes.muted),
            FormattedLine("films       4", Vulpes.muted),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(url: url, header: "weekly", build: { json in
            var lines: [FormattedLine] = []
            let d = json as? [String: Any]
            if let ws = d?["weeklySummary"] as? [String: Any] {
                if let ph = ws["productiveHours"] as? Double {
                    lines.append(FormattedLine("productive  \(String(format: "%.1f", ph))h", Vulpes.lightPink))
                }
                if let th = ws["totalTrackedHours"] as? Double {
                    lines.append(FormattedLine("tracked     \(String(format: "%.1f", th))h", Vulpes.dimPink))
                }
                if let pp = ws["productivityPercent"] as? Double {
                    lines.append(FormattedLine("efficiency  \(String(format: "%.0f", pp))% \(bar(pp, max: 100))", Vulpes.dimPink))
                }
            }
            if let lf = d?["lastfm"] as? [String: Any], let sc = lf["scrobbles"] {
                lines.append(FormattedLine("scrobbles   \(sc)", Vulpes.muted))
            }
            if let lt = d?["letterboxd"] as? [String: Any], let f = lt["films"] {
                lines.append(FormattedLine("films       \(f)", Vulpes.muted))
            }
            return lines
        }, completion: completion)
    }
}

// MARK: - Words this month

class WordsStream: DataStream {
    let name = "words"
    let url: String
    init(url: String) { self.url = url }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("words this month", Vulpes.teal),
            FormattedLine("April 2026", Vulpes.lightPink),
            FormattedLine("words  12450", Vulpes.dimPink),
            FormattedLine("posts  8", Vulpes.dimPink),
            FormattedLine("avg    1556 / post", Vulpes.muted),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(url: url, header: "words this month", build: { json in
            var lines: [FormattedLine] = []
            let d = json as? [String: Any]
            if let m = d?["month"], let y = d?["year"] {
                lines.append(FormattedLine("\(m) \(y)", Vulpes.lightPink))
            }
            if let w = d?["totalWords"] { lines.append(FormattedLine("words  \(w)", Vulpes.dimPink)) }
            if let p = d?["postCount"] { lines.append(FormattedLine("posts  \(p)", Vulpes.dimPink)) }
            if let a = d?["avgWordsPerPost"] { lines.append(FormattedLine("avg    \(a) / post", Vulpes.muted)) }
            return lines
        }, completion: completion)
    }
}

// MARK: - LeetCode

class LeetCodeStream: DataStream {
    let name = "leetcode"
    let url: String
    init(url: String) { self.url = url }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("leetcode.com", Vulpes.teal),
            FormattedLine("easy     147 solved", Vulpes.lightPink),
            FormattedLine("medium   62 solved", Vulpes.lightPink),
            FormattedLine("hard     14 solved", Vulpes.hotPink),
            FormattedLine("", Vulpes.muted),
            FormattedLine("recent", Vulpes.mutedMagenta),
            FormattedLine("  two sum", Vulpes.dimPink),
            FormattedLine("  valid parentheses", Vulpes.dimPink),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(url: url, header: "leetcode.com", build: { json in
            var lines: [FormattedLine] = []
            let d = json as? [String: Any]
            if let ss = d?["submissionStats"] as? [String: Any] {
                for diff in ["easy", "medium", "hard"] {
                    if let s = ss[diff] as? [String: Any], let c = s["count"] {
                        let label = diff.padding(toLength: 8, withPad: " ", startingAt: 0)
                        let color = diff == "hard" ? Vulpes.hotPink : Vulpes.lightPink
                        lines.append(FormattedLine("\(label) \(c) solved", color))
                    }
                }
            }
            if let recent = d?["recentSubmissions"] as? [[String: Any]] {
                lines.append(FormattedLine("", Vulpes.muted))
                lines.append(FormattedLine("recent", Vulpes.mutedMagenta))
                for sub in recent.prefix(3) {
                    let title = sub["title"] as? String ?? "?"
                    for chunk in wrapText(title, width: 30).prefix(2) {
                        lines.append(FormattedLine("  \(chunk.lowercased())", Vulpes.dimPink))
                    }
                }
            }
            return lines
        }, completion: completion)
    }
}

// MARK: - Mastodon

class MastodonStream: DataStream {
    let name = "mastodon"
    let url: String
    init(url: String) { self.url = url }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("@ejfox@mastodon.social", Vulpes.dimTeal),
            FormattedLine("", Vulpes.muted),
            FormattedLine("2026-04-19", Vulpes.mutedMagenta),
            FormattedLine("  shipped a thing today", Vulpes.lightPink),
            FormattedLine("  feels good", Vulpes.lightPink),
            FormattedLine("", Vulpes.muted),
            FormattedLine("2026-04-18", Vulpes.mutedMagenta),
            FormattedLine("  new vulpes shader chain", Vulpes.lightPink),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(url: url, timeout: 15, header: "@ejfox@mastodon.social", build: { json in
            var lines: [FormattedLine] = []
            guard let posts = json as? [[String: Any]] else { return lines }
            for post in posts.prefix(2) {
                let content = (post["content"] as? String ?? "")
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let date = String((post["created_at"] as? String ?? "").prefix(10))
                lines.append(FormattedLine("", Vulpes.muted))
                lines.append(FormattedLine(date, Vulpes.mutedMagenta))
                for chunk in wrapText(content, width: 34).prefix(3) {
                    lines.append(FormattedLine("  \(chunk)", Vulpes.lightPink))
                }
            }
            return lines
        }, completion: completion)
    }
}
