import Foundation

/// Builds `DataStream` instances from string IDs in the user's config.
/// Any unknown ID is logged and skipped.
///
/// Stream IDs are stable — renaming one requires a migration note.
///
/// Special dynamic prefixes:
///   - `shell:<cmd> [args...]`   — ShellStream, runs a local command
///   - `term:<label>@<url>`      — TerminalStream, polls URL for plain text
/// Examples:
///   - `shell:top -l 1 -n 10 -o cpu`  → local `top` output
///   - `term:vps@https://vps.example.com/api/top` → remote terminal dump
enum StreamFactory {
    static func make(_ id: String, config: CyberdeckConfig) -> DataStream? {
        // Dynamic shell command: "shell:/path/to/bin arg1 arg2"
        // (falls back to common paths if the first token isn't absolute)
        if id.hasPrefix("shell:") {
            let cmd = String(id.dropFirst("shell:".count))
            let tokens = cmd.split(separator: " ").map(String.init)
            guard let first = tokens.first else { return nil }
            let path = first.hasPrefix("/") ? first : resolveCommand(first)
            let args = Array(tokens.dropFirst())
            let label = (first as NSString).lastPathComponent
            return ShellStream(label: label, path: path, args: args)
        }

        // Dynamic URL-backed terminal: "term:<label>@<url>"
        if id.hasPrefix("term:") {
            let rest = String(id.dropFirst("term:".count))
            if let at = rest.firstIndex(of: "@") {
                let label = String(rest[..<at])
                let url = String(rest[rest.index(after: at)...])
                return TerminalStream(label: label, url: url)
            }
            return TerminalStream(label: "terminal", url: rest)
        }

        switch id {
        // System / local
        case "command": return CommandStream()
        case "system":  return SystemStream()

        // Personal APIs
        case "github":     return GitHubStream(url: config.apis.stats)
        case "music":      return MusicStream(url: config.apis.lastfm)
        case "health":     return HealthStream(url: config.apis.stats)
        case "chess":      return ChessStream(url: config.apis.chess)
        case "monkeytype": return TypingStream(url: config.apis.monkeytype)
        case "rescuetime": return RescueTimeStream(url: config.apis.rescuetime)
        case "stats":      return StatsStream(url: config.apis.stats)
        case "words":      return WordsStream(url: config.apis.words)
        case "leetcode":   return LeetCodeStream(url: config.apis.leetcode)
        case "mastodon":   return MastodonStream(url: config.apis.mastodon)

        // EJ's VPS OSINT tools
        case "skywatch":  return SkywatchStream(url: config.apis.skywatch)
        case "anomaly":   return AnomalywatchStream(url: config.apis.anomaly)
        case "briefings": return BriefingsStream(url: config.apis.briefings)

        // Public realtime feeds
        case "seismic":  return SeismicStream()
        case "solar":    return SolarStream()
        case "iss":      return ISSStream(lat: config.location.lat, lon: config.location.lon)
        case "threat":   return ThreatStream()
        case "airspace": return AirspaceStream(bbox: config.airspace)

        // Scrapbook — all share config.apis.scraps; StreamCache dedupes.
        case "scraps":   return ArchiveStream(name: "archive",  url: config.apis.scraps)
        case "entities": return EntitiesStream(name: "entities", url: config.apis.scraps)
        case "places":   return PlacesStream(name: "places",    url: config.apis.scraps,
                                             observerLat: config.location.lat,
                                             observerLon: config.location.lon)
        case "concepts": return ConceptsStream(name: "concepts", url: config.apis.scraps)
        case "memory":   return MemoryStream(name: "memory",    url: config.apis.scraps)
        case "intake":   return IntakeStream(name: "intake",    url: config.apis.scraps)
        case "facts":    return FactsStream(name: "facts",      url: config.apis.scraps)
        case "trending": return TrendingStream(name: "trending", url: config.apis.scraps)

        default:
            Diag.log("StreamFactory: unknown stream id '\(id)'")
            return nil
        }
    }

    private static let commonBinPaths = [
        "/usr/bin/", "/bin/", "/usr/local/bin/", "/opt/homebrew/bin/",
    ]

    private static func resolveCommand(_ name: String) -> String {
        let fm = FileManager.default
        for prefix in commonBinPaths {
            let candidate = prefix + name
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/bin/\(name)"  // best-effort fallback
    }
}
