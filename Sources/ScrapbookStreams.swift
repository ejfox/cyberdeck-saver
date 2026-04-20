import AppKit
import Foundation

/// Scrapbook modules. All share a single endpoint (`config.apis.scraps`) which
/// returns the 500 most-recent scraps with AI-extracted fields. `StreamCache`
/// guarantees one network round-trip per refresh window serves every display's
/// worth of scrapbook panels.
///
/// Each stream parses the shared response into its own view; there's no shared
/// state between them beyond the cache.

// MARK: - Shared helpers

/// Great-circle distance in miles (haversine).
private func scrapHaversineMiles(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let R = 3958.8
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
        + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
        * sin(dLon / 2) * sin(dLon / 2)
    return 2 * R * atan2(sqrt(a), sqrt(1 - a))
}

/// Single-char glyph for each source — keeps archive lines scannable.
private func sourceGlyph(_ source: String?) -> String {
    switch source?.lowercased() {
    case "pinboard":  return "p"
    case "arena":     return "a"
    case "github":    return "g"
    case "mastodon":  return "m"
    default:          return "·"
    }
}

/// Lowercased, clipped title — keeps the cyberdeck utilitarian feel consistent.
private func normalizeTitle(_ raw: String?, width: Int = 32) -> String {
    let cleaned = (raw ?? "untitled")
        .lowercased()
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(cleaned.prefix(width))
}

// MARK: - Base class

/// Every scrapbook stream hits the same URL and parses the shared response
/// differently. Subclasses override `format(scraps:)` with their specific view.
class ScrapbookStream: DataStream {
    let name: String
    let url: String
    let observerLat: Double
    let observerLon: Double

    init(name: String, url: String, observerLat: Double = 41.93, observerLon: Double = -74.0) {
        self.name = name
        self.url = url
        self.observerLat = observerLat
        self.observerLon = observerLon
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        // 5 min cache window — matches typical scrap ingestion cadence and
        // coalesces across scrapbook panels + displays.
        ApiClient.fetchJSON(from: url, timeout: 20, cacheMaxAge: 300) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let json):
                let scraps = (json as? [[String: Any]]) ?? []
                let lines = [FormattedLine(self.header, Vulpes.teal)] + self.format(scraps: scraps)
                completion(StreamResponse(lines: lines, ok: true))
            case .failure(let err):
                completion(StreamResponse(lines: [
                    FormattedLine(self.header, Vulpes.orange),
                    FormattedLine("status: \(err.label)", Vulpes.orange),
                    FormattedLine("retrying soon", Vulpes.muted),
                ], ok: false))
            }
        }
    }

    /// Override. Header line rendered in the "teal" slot above the parsed body.
    var header: String { "scrapbook" }

    /// Override. Convert the full scrap array into this module's view.
    func format(scraps: [[String: Any]]) -> [FormattedLine] { [] }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [FormattedLine(header, Vulpes.teal)] + previewBody, ok: true)
    }

    /// Override. Hand-written canned data for System Settings preview.
    var previewBody: [FormattedLine] { [] }
}

// MARK: - 1. archive — latest scrap intake

final class ArchiveStream: ScrapbookStream {
    override var header: String { "archive intake" }

    override func format(scraps: [[String: Any]]) -> [FormattedLine] {
        var lines: [FormattedLine] = []
        lines.append(FormattedLine("total  \(scraps.count) recent", Vulpes.dimPink))
        lines.append(FormattedLine("", Vulpes.muted))
        for scrap in scraps.prefix(5) {
            let glyph = sourceGlyph(scrap["source"] as? String)
            let title = normalizeTitle(scrap["title"] as? String, width: 32)
            lines.append(FormattedLine("[\(glyph)] \(title)", Vulpes.lightPink))
        }
        return lines
    }

    override var previewBody: [FormattedLine] {
        [
            FormattedLine("total  487 recent", Vulpes.dimPink),
            FormattedLine("", Vulpes.muted),
            FormattedLine("[p] bloom shader implementation", Vulpes.lightPink),
            FormattedLine("[a] field notes — terminal ui", Vulpes.lightPink),
            FormattedLine("[g] ejfox/cyberdeck-saver", Vulpes.lightPink),
            FormattedLine("[m] post about tmux configs", Vulpes.lightPink),
            FormattedLine("[p] metal shader primer 2024", Vulpes.lightPink),
        ]
    }
}

// MARK: - 2. entities — flatten relationships, count by name

final class EntitiesStream: ScrapbookStream {
    override var header: String { "extracted entities" }

    override func format(scraps: [[String: Any]]) -> [FormattedLine] {
        // relationships[] shape varies; two forms observed:
        //   { source: {name, type}, target: {name, type}, type: predicate }
        //   { source: "name", target: "name", sourceType, targetType, relationship }
        // Flatten both into (name, type) pairs and count.
        var counts: [String: (type: String, n: Int)] = [:]

        func bump(_ name: String?, _ type: String?) {
            guard let n = name?.lowercased(), !n.isEmpty, n.count < 40 else { return }
            let t = type?.lowercased() ?? "entity"
            counts[n, default: (t, 0)].n += 1
            counts[n]?.type = t
        }

        for scrap in scraps {
            guard let rels = scrap["relationships"] as? [[String: Any]] else { continue }
            for rel in rels {
                if let src = rel["source"] as? [String: Any] {
                    bump(src["name"] as? String, src["type"] as? String)
                } else if let s = rel["source"] as? String {
                    bump(s, rel["sourceType"] as? String)
                }
                if let tgt = rel["target"] as? [String: Any] {
                    bump(tgt["name"] as? String, tgt["type"] as? String)
                } else if let t = rel["target"] as? String {
                    bump(t, rel["targetType"] as? String)
                }
            }
        }

        let ranked = counts
            .map { (name: $0.key, type: $0.value.type, n: $0.value.n) }
            .sorted { $0.n > $1.n }

        var lines: [FormattedLine] = [FormattedLine("", Vulpes.muted)]
        if ranked.isEmpty {
            lines.append(FormattedLine("no extractions", Vulpes.muted))
            return lines
        }
        for entity in ranked.prefix(6) {
            let color = colorFor(type: entity.type)
            let clipped = String(entity.name.prefix(28))
            lines.append(FormattedLine("\(entity.n)× \(clipped)", color))
        }
        return lines
    }

    private func colorFor(type: String) -> NSColor {
        switch type {
        case "person", "people":              return Vulpes.hotPink
        case "organization", "org", "company": return Vulpes.lightPink
        case "location", "place":              return Vulpes.teal
        case "concept", "topic":               return Vulpes.dimPink
        default:                               return Vulpes.muted
        }
    }

    override var previewBody: [FormattedLine] {
        [
            FormattedLine("", Vulpes.muted),
            FormattedLine("14× anthropic", Vulpes.lightPink),
            FormattedLine("11× hudson valley", Vulpes.teal),
            FormattedLine("9× claude shannon", Vulpes.hotPink),
            FormattedLine("8× metal framework", Vulpes.dimPink),
            FormattedLine("7× new york times", Vulpes.lightPink),
            FormattedLine("6× alan kay", Vulpes.hotPink),
        ]
    }
}

// MARK: - 3. places — geocoded scraps by proximity

final class PlacesStream: ScrapbookStream {
    override var header: String { "geocoded scraps" }

    override func format(scraps: [[String: Any]]) -> [FormattedLine] {
        // Items with lat/lon — sort by distance from observer.
        struct PlaceScrap {
            let name: String
            let dist: Double
        }
        let geo: [PlaceScrap] = scraps.compactMap { scrap in
            guard let lat = scrap["latitude"] as? Double,
                  let lon = scrap["longitude"] as? Double else { return nil }
            let name = (scrap["location"] as? String)
                ?? normalizeTitle(scrap["title"] as? String, width: 24)
            let dist = scrapHaversineMiles(lat1: observerLat, lon1: observerLon, lat2: lat, lon2: lon)
            return PlaceScrap(name: name.lowercased(), dist: dist)
        }

        let sorted = geo.sorted { $0.dist < $1.dist }
        var lines: [FormattedLine] = []
        lines.append(FormattedLine("geo-tagged  \(geo.count)", Vulpes.dimPink))
        lines.append(FormattedLine("", Vulpes.muted))

        for place in sorted.prefix(5) {
            let dist = place.dist
            let distStr: String
            let color: NSColor
            if dist < 50 {
                distStr = String(format: "%.0fmi", dist); color = Vulpes.hotPink
            } else if dist < 500 {
                distStr = String(format: "%.0fmi", dist); color = Vulpes.lightPink
            } else {
                distStr = String(format: "%.0fmi", dist); color = Vulpes.dimPink
            }
            let clipped = String(place.name.prefix(22))
            lines.append(FormattedLine("\(distStr.padding(toLength: 7, withPad: " ", startingAt: 0)) \(clipped)", color))
        }
        return lines
    }

    override var previewBody: [FormattedLine] {
        [
            FormattedLine("geo-tagged  73", Vulpes.dimPink),
            FormattedLine("", Vulpes.muted),
            FormattedLine("4mi     kingston ny", Vulpes.hotPink),
            FormattedLine("83mi    brooklyn", Vulpes.lightPink),
            FormattedLine("215mi   boston", Vulpes.lightPink),
            FormattedLine("2442mi  los angeles", Vulpes.dimPink),
            FormattedLine("3482mi  berlin", Vulpes.dimPink),
        ]
    }
}

// MARK: - 4. concepts — top concept_tags

final class ConceptsStream: ScrapbookStream {
    override var header: String { "concept frequency" }

    override func format(scraps: [[String: Any]]) -> [FormattedLine] {
        var counts: [String: Int] = [:]
        for scrap in scraps {
            guard let tags = scrap["concept_tags"] as? [String] else { continue }
            for tag in tags {
                let normalized = tag.lowercased()
                guard !normalized.isEmpty, normalized.count < 30 else { continue }
                counts[normalized, default: 0] += 1
            }
        }

        let ranked = counts.sorted { $0.value > $1.value }
        var lines: [FormattedLine] = [FormattedLine("", Vulpes.muted)]
        if ranked.isEmpty {
            lines.append(FormattedLine("no concept tags", Vulpes.muted))
            return lines
        }
        let topCount = ranked.first?.value ?? 1
        for (tag, count) in ranked.prefix(6) {
            let barWidth = 6
            let filled = Int(Double(count) / Double(topCount) * Double(barWidth))
            let barStr = String(repeating: "\u{2588}", count: filled)
                + String(repeating: "\u{2591}", count: barWidth - filled)
            let clipped = String(tag.prefix(20))
            lines.append(FormattedLine("\(barStr) \(clipped)", Vulpes.lightPink))
        }
        return lines
    }

    override var previewBody: [FormattedLine] {
        [
            FormattedLine("", Vulpes.muted),
            FormattedLine("██████ programming", Vulpes.lightPink),
            FormattedLine("█████░ ai research", Vulpes.lightPink),
            FormattedLine("████░░ journalism", Vulpes.lightPink),
            FormattedLine("███░░░ hudson valley", Vulpes.lightPink),
            FormattedLine("██░░░░ typography", Vulpes.lightPink),
            FormattedLine("██░░░░ cartography", Vulpes.lightPink),
        ]
    }
}

// MARK: - 5. memory — random scrap resurrection

final class MemoryStream: ScrapbookStream {
    override var header: String { "memory dredge" }

    override func format(scraps: [[String: Any]]) -> [FormattedLine] {
        guard !scraps.isEmpty else {
            return [FormattedLine("empty archive", Vulpes.muted)]
        }
        // Pick a scrap deterministically per refresh window so the panel
        // "holds" on one memory until the next fetch rotates to another.
        let seed = Int(Date().timeIntervalSince1970 / 300)  // 5min bucket
        let index = abs(seed) % scraps.count
        let scrap = scraps[index]

        var lines: [FormattedLine] = []
        let source = (scrap["source"] as? String)?.lowercased() ?? "archive"
        let age = ageDescription(from: scrap["created_at"] as? String)
        lines.append(FormattedLine("\(source) · \(age)", Vulpes.mutedMagenta))
        lines.append(FormattedLine("", Vulpes.muted))

        let title = scrap["title"] as? String ?? "untitled"
        for chunk in wrapText(title.lowercased(), width: 32).prefix(2) {
            lines.append(FormattedLine(chunk, Vulpes.hotPink))
        }

        if let summary = scrap["summary"] as? String, !summary.isEmpty {
            lines.append(FormattedLine("", Vulpes.muted))
            for chunk in wrapText(summary.lowercased(), width: 34).prefix(4) {
                lines.append(FormattedLine(chunk, Vulpes.lightPink))
            }
        }
        return lines
    }

    private func ageDescription(from isoString: String?) -> String {
        guard let s = isoString else { return "archive" }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fmt.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        guard let d = date else { return "archive" }
        let age = Date().timeIntervalSince(d)
        let days = Int(age / 86400)
        if days < 1 { return "today" }
        if days < 7 { return "\(days)d ago" }
        if days < 30 { return "\(days / 7)w ago" }
        if days < 365 { return "\(days / 30)mo ago" }
        return "\(days / 365)y ago"
    }

    override var previewBody: [FormattedLine] {
        [
            FormattedLine("pinboard · 4y ago", Vulpes.mutedMagenta),
            FormattedLine("", Vulpes.muted),
            FormattedLine("the memex revisited", Vulpes.hotPink),
            FormattedLine("", Vulpes.muted),
            FormattedLine("vannevar bush's 1945 essay on", Vulpes.lightPink),
            FormattedLine("personal information retrieval", Vulpes.lightPink),
            FormattedLine("anticipating hypertext and", Vulpes.lightPink),
            FormattedLine("networked knowledge systems", Vulpes.lightPink),
        ]
    }
}

// MARK: - 6. facts — extracted claim triples (subject → predicate → object)

final class FactsStream: ScrapbookStream {
    override var header: String { "extracted facts" }

    /// Words we don't want to surface as "claims" — mostly bookkeeping verbs
    /// from the extractor that aren't substantive edges.
    private static let boringPredicates: Set<String> = [
        "mentioned", "mentions", "references", "referenced", "cited",
        "related", "associated", "about",
    ]

    override func format(scraps: [[String: Any]]) -> [FormattedLine] {
        struct Triple {
            let subject: String
            let predicate: String
            let object: String
        }
        var triples: [Triple] = []

        for scrap in scraps.prefix(50) {
            guard let rels = scrap["relationships"] as? [[String: Any]] else { continue }
            for rel in rels {
                let subject = (rel["source"] as? [String: Any])?["name"] as? String
                    ?? rel["source"] as? String
                let object = (rel["target"] as? [String: Any])?["name"] as? String
                    ?? rel["target"] as? String
                let predicate = (rel["type"] as? String) ?? (rel["relationship"] as? String)

                guard let s = subject?.lowercased(),
                      let o = object?.lowercased(),
                      let p = predicate?.lowercased().replacingOccurrences(of: "_", with: " "),
                      !s.isEmpty, !o.isEmpty, !p.isEmpty,
                      !Self.boringPredicates.contains(p) else { continue }

                triples.append(Triple(subject: s, predicate: p, object: o))
                if triples.count >= 40 { break }
            }
            if triples.count >= 40 { break }
        }

        var lines: [FormattedLine] = [FormattedLine("", Vulpes.muted)]
        if triples.isEmpty {
            lines.append(FormattedLine("no claims indexed", Vulpes.muted))
            return lines
        }

        // Surface the first 4 triples in the current fetch window. Rendered
        // as two lines each (subject/predicate → object) so the claim reads.
        for triple in triples.prefix(4) {
            let subj = String(triple.subject.prefix(22))
            let pred = String(triple.predicate.prefix(18))
            let obj = String(triple.object.prefix(28))
            lines.append(FormattedLine("\(subj) \(pred)", Vulpes.hotPink))
            lines.append(FormattedLine("  → \(obj)", Vulpes.lightPink))
        }
        return lines
    }

    override var previewBody: [FormattedLine] {
        [
            FormattedLine("", Vulpes.muted),
            FormattedLine("anthropic founded", Vulpes.hotPink),
            FormattedLine("  → san francisco", Vulpes.lightPink),
            FormattedLine("claude shannon worked at", Vulpes.hotPink),
            FormattedLine("  → bell labs", Vulpes.lightPink),
            FormattedLine("vannevar bush authored", Vulpes.hotPink),
            FormattedLine("  → as we may think", Vulpes.lightPink),
            FormattedLine("tim berners-lee invented", Vulpes.hotPink),
            FormattedLine("  → world wide web", Vulpes.lightPink),
        ]
    }
}

// MARK: - 7. trending — entities spiking in recent window

final class TrendingStream: ScrapbookStream {
    override var header: String { "trending entities" }

    override func format(scraps: [[String: Any]]) -> [FormattedLine] {
        // Split the window: first 50 scraps = "recent", next 450 = "baseline".
        // Weight recent mentions 5× so a brand-new entity with few mentions
        // can still out-score a steady old name.
        let recentCutoff = min(50, scraps.count)
        var recentCounts: [String: Int] = [:]
        var olderCounts: [String: Int] = [:]

        func collectNames(_ rels: [[String: Any]]) -> [String] {
            var names: [String] = []
            for rel in rels {
                if let src = rel["source"] as? [String: Any],
                   let n = (src["name"] as? String)?.lowercased(), !n.isEmpty {
                    names.append(n)
                } else if let s = (rel["source"] as? String)?.lowercased(), !s.isEmpty {
                    names.append(s)
                }
                if let tgt = rel["target"] as? [String: Any],
                   let n = (tgt["name"] as? String)?.lowercased(), !n.isEmpty {
                    names.append(n)
                } else if let t = (rel["target"] as? String)?.lowercased(), !t.isEmpty {
                    names.append(t)
                }
            }
            return names
        }

        for (i, scrap) in scraps.enumerated() {
            guard let rels = scrap["relationships"] as? [[String: Any]] else { continue }
            let names = collectNames(rels)
            if i < recentCutoff {
                for n in names { recentCounts[n, default: 0] += 1 }
            } else {
                for n in names { olderCounts[n, default: 0] += 1 }
            }
        }

        // Score = recent * 5 - older. Filter out short junk names.
        let scored = recentCounts.compactMap { (name, recent) -> (String, Int, Int)? in
            guard name.count >= 3, name.count < 35 else { return nil }
            let older = olderCounts[name] ?? 0
            let score = recent * 5 - older
            return score > 0 ? (name, recent, score) : nil
        }.sorted { $0.2 > $1.2 }

        var lines: [FormattedLine] = [FormattedLine("", Vulpes.muted)]
        if scored.isEmpty {
            lines.append(FormattedLine("no spikes detected", Vulpes.muted))
            return lines
        }
        for (name, recent, _) in scored.prefix(5) {
            let clipped = String(name.prefix(24))
            lines.append(FormattedLine("\u{25B2}\(recent)  \(clipped)", Vulpes.hotPink))
        }
        return lines
    }

    override var previewBody: [FormattedLine] {
        [
            FormattedLine("", Vulpes.muted),
            FormattedLine("▲8   metal framework", Vulpes.hotPink),
            FormattedLine("▲6   screen saver", Vulpes.hotPink),
            FormattedLine("▲5   vulpes palette", Vulpes.hotPink),
            FormattedLine("▲4   core text", Vulpes.hotPink),
            FormattedLine("▲3   sandbox", Vulpes.hotPink),
        ]
    }
}

// MARK: - 8. intake — freshest per source (optional, off by default)

final class IntakeStream: ScrapbookStream {
    override var header: String { "source intake" }

    override func format(scraps: [[String: Any]]) -> [FormattedLine] {
        // Walk the already-sorted array and take the first scrap per source.
        var seen: [String: [String: Any]] = [:]
        for scrap in scraps {
            let source = (scrap["source"] as? String)?.lowercased() ?? "?"
            if seen[source] == nil { seen[source] = scrap }
            if seen.count >= 4 { break }
        }

        var lines: [FormattedLine] = [FormattedLine("", Vulpes.muted)]
        let order = ["pinboard", "arena", "github", "mastodon"]
        for source in order {
            guard let scrap = seen[source] else { continue }
            let glyph = sourceGlyph(source)
            let title = normalizeTitle(scrap["title"] as? String, width: 28)
            lines.append(FormattedLine("[\(glyph)] \(title)", Vulpes.lightPink))
        }
        return lines
    }

    override var previewBody: [FormattedLine] {
        [
            FormattedLine("", Vulpes.muted),
            FormattedLine("[p] metal shader primer", Vulpes.lightPink),
            FormattedLine("[a] field notes — terminal ui", Vulpes.lightPink),
            FormattedLine("[g] ejfox/cyberdeck-saver", Vulpes.lightPink),
            FormattedLine("[m] shipped a thing today", Vulpes.lightPink),
        ]
    }
}
