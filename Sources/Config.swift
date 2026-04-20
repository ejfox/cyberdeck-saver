import Foundation

/// User-editable config. Lives at:
///   ~/Library/Application Support/CyberdeckSaver/config.json
///
/// On first launch the file is created with sensible defaults. Edit it by hand
/// and restart the screensaver to apply changes. Unknown fields are ignored, so
/// the schema can evolve without breaking older configs.
///
/// Environment override: set `CYBERDECK_CONFIG=/path/to/custom.json` to point
/// at a different file (useful for testing).
struct CyberdeckConfig: Codable {
    var location: LocationConfig
    var airspace: AirspaceConfig
    var apis: APIUrls
    var render: RenderConfig
    var panels: [PanelConfig]

    static let `default` = CyberdeckConfig(
        location: .default,
        airspace: .default,
        apis: .default,
        render: .default,
        panels: PanelConfig.defaults
    )
}

struct LocationConfig: Codable {
    var lat: Double
    var lon: Double
    var label: String

    static let `default` = LocationConfig(lat: 41.93, lon: -74.00, label: "hudson valley")
}

struct AirspaceConfig: Codable {
    var minLat: Double
    var maxLat: Double
    var minLon: Double
    var maxLon: Double

    static let `default` = AirspaceConfig(minLat: 41.0, maxLat: 42.5, minLon: -75.0, maxLon: -73.0)
}

struct APIUrls: Codable {
    var stats: String
    var lastfm: String
    var chess: String
    var monkeytype: String
    var rescuetime: String
    var leetcode: String
    var words: String
    var mastodon: String
    var skywatch: String
    var anomaly: String
    var briefings: String
    var scraps: String

    static let `default` = APIUrls(
        stats:      "https://ejfox.com/api/stats",
        lastfm:     "https://ejfox.com/api/lastfm",
        chess:      "https://ejfox.com/api/chess",
        monkeytype: "https://ejfox.com/api/monkeytype",
        rescuetime: "https://ejfox.com/api/rescuetime",
        leetcode:   "https://ejfox.com/api/leetcode",
        words:      "https://ejfox.com/api/words-this-month",
        mastodon:   "https://mastodon-posts.ejfox.tools/",
        skywatch:   "https://skywatch.tools.ejfox.com/api/stats",
        anomaly:    "https://anomalywatch.tools.ejfox.com/api/stats",
        briefings:  "https://briefings.tools.ejfox.com/api/reports",
        scraps:     "https://ejfox.com/api/scraps"
    )

    // Back-compat: tolerate a config file written before `scraps` existed.
    enum CodingKeys: String, CodingKey {
        case stats, lastfm, chess, monkeytype, rescuetime, leetcode,
             words, mastodon, skywatch, anomaly, briefings, scraps
    }

    init(stats: String, lastfm: String, chess: String, monkeytype: String,
         rescuetime: String, leetcode: String, words: String, mastodon: String,
         skywatch: String, anomaly: String, briefings: String, scraps: String) {
        self.stats = stats; self.lastfm = lastfm; self.chess = chess
        self.monkeytype = monkeytype; self.rescuetime = rescuetime
        self.leetcode = leetcode; self.words = words; self.mastodon = mastodon
        self.skywatch = skywatch; self.anomaly = anomaly; self.briefings = briefings
        self.scraps = scraps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = APIUrls.default
        self.stats      = (try? c.decode(String.self, forKey: .stats)) ?? d.stats
        self.lastfm     = (try? c.decode(String.self, forKey: .lastfm)) ?? d.lastfm
        self.chess      = (try? c.decode(String.self, forKey: .chess)) ?? d.chess
        self.monkeytype = (try? c.decode(String.self, forKey: .monkeytype)) ?? d.monkeytype
        self.rescuetime = (try? c.decode(String.self, forKey: .rescuetime)) ?? d.rescuetime
        self.leetcode   = (try? c.decode(String.self, forKey: .leetcode)) ?? d.leetcode
        self.words      = (try? c.decode(String.self, forKey: .words)) ?? d.words
        self.mastodon   = (try? c.decode(String.self, forKey: .mastodon)) ?? d.mastodon
        self.skywatch   = (try? c.decode(String.self, forKey: .skywatch)) ?? d.skywatch
        self.anomaly    = (try? c.decode(String.self, forKey: .anomaly)) ?? d.anomaly
        self.briefings  = (try? c.decode(String.self, forKey: .briefings)) ?? d.briefings
        self.scraps     = (try? c.decode(String.self, forKey: .scraps)) ?? d.scraps
    }
}

struct RenderConfig: Codable {
    /// Enable the glitch shader pass (chromatic aberration + analog distortion).
    var glitch: Bool
    /// Force performance mode regardless of GPU. `"full"`, `"lite"`, or nil to auto-detect.
    var forceMode: String?
    /// Font size for panel text. Defaults to 12.
    var fontSize: Double
    /// Max Hz for Core Text redraws. Metal shaders still run at full display rate
    /// (vsync), but the expensive CPU-side text rasterization is throttled to this.
    /// Default 30 is plenty smooth for typewriter animation; raise to 60 if CPU permits.
    var textRedrawHz: Double

    static let `default` = RenderConfig(glitch: false, forceMode: nil, fontSize: 12.0, textRedrawHz: 60.0)

    init(glitch: Bool, forceMode: String?, fontSize: Double, textRedrawHz: Double = 60.0) {
        self.glitch = glitch
        self.forceMode = forceMode
        self.fontSize = fontSize
        self.textRedrawHz = textRedrawHz
    }

    enum CodingKeys: String, CodingKey {
        case glitch, forceMode, fontSize, textRedrawHz
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.glitch = (try? c.decode(Bool.self, forKey: .glitch)) ?? false
        self.forceMode = try? c.decode(String.self, forKey: .forceMode)
        self.fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? 12.0
        self.textRedrawHz = (try? c.decode(Double.self, forKey: .textRedrawHz)) ?? 60.0
    }
}

/// A single panel slot. `streams` is an array so the slot can rotate through
/// multiple data sources. `rotationInterval` = 0 means no rotation.
struct PanelConfig: Codable {
    var name: String
    var streams: [String]
    var typingSpeed: Double
    var refreshInterval: TimeInterval
    var rotationInterval: TimeInterval

    init(name: String, streams: [String], typingSpeed: Double = 1200,
         refreshInterval: TimeInterval = 60, rotationInterval: TimeInterval = 0) {
        self.name = name
        self.streams = streams
        self.typingSpeed = typingSpeed
        self.refreshInterval = refreshInterval
        self.rotationInterval = rotationInterval
    }

    enum CodingKeys: String, CodingKey {
        case name, streams, stream, typingSpeed, refreshInterval, rotationInterval
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        if let arr = try? c.decode([String].self, forKey: .streams) {
            self.streams = arr
        } else if let single = try? c.decode(String.self, forKey: .stream) {
            self.streams = [single]
        } else {
            self.streams = []
        }
        self.typingSpeed = (try? c.decode(Double.self, forKey: .typingSpeed)) ?? 1200
        self.refreshInterval = (try? c.decode(TimeInterval.self, forKey: .refreshInterval)) ?? 60
        self.rotationInterval = (try? c.decode(TimeInterval.self, forKey: .rotationInterval)) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(streams, forKey: .streams)
        try c.encode(typingSpeed, forKey: .typingSpeed)
        try c.encode(refreshInterval, forKey: .refreshInterval)
        if rotationInterval > 0 {
            try c.encode(rotationInterval, forKey: .rotationInterval)
        }
    }

    // Stream IDs are the authoritative names for data sources.
    // Panel labels are display-only and point at whatever source is primary
    // for that slot — utilitarian, descriptive, no parody intel jargon.
    static let defaults: [PanelConfig] = [
        // Row 0 — time + live airspace
        PanelConfig(name: "clock",     streams: ["command"],    typingSpeed: 9999, refreshInterval: 1),
        PanelConfig(name: "skywatch",  streams: ["skywatch"],   typingSpeed: 1500, refreshInterval: 60),
        PanelConfig(name: "ads-b",     streams: ["airspace"],   typingSpeed: 1200, refreshInterval: 30),
        PanelConfig(name: "anomaly",   streams: ["anomaly"],    typingSpeed: 1200, refreshInterval: 45),
        PanelConfig(name: "urlhaus",   streams: ["threat"],     typingSpeed: 1000, refreshInterval: 180),
        // Row 1 — intel + comms + seismic
        PanelConfig(name: "briefings", streams: ["briefings"],  typingSpeed: 1000, refreshInterval: 300),
        PanelConfig(name: "github",    streams: ["github"],     typingSpeed: 1500, refreshInterval: 90),
        PanelConfig(name: "last.fm",   streams: ["music"],      typingSpeed: 1200, refreshInterval: 30),
        PanelConfig(name: "mastodon",  streams: ["mastodon"],   typingSpeed: 1000, refreshInterval: 60),
        PanelConfig(name: "usgs",      streams: ["seismic"],    typingSpeed: 1200, refreshInterval: 300),
        // Row 2 — personal telemetry + geospace
        PanelConfig(name: "health",    streams: ["health"],     typingSpeed: 1500, refreshInterval: 120),
        PanelConfig(name: "system",    streams: ["system"],     typingSpeed: 2000, refreshInterval: 10),
        PanelConfig(name: "rescuetime",streams: ["rescuetime"], typingSpeed: 1200, refreshInterval: 120),
        PanelConfig(name: "stats",     streams: ["stats"],      typingSpeed: 1500, refreshInterval: 120),
        PanelConfig(name: "solar",     streams: ["solar"],      typingSpeed: 1200, refreshInterval: 600),
        // Row 3 — skills + orbit
        PanelConfig(name: "chess",     streams: ["chess"],      typingSpeed: 1200, refreshInterval: 300),
        PanelConfig(name: "monkeytype",streams: ["monkeytype"], typingSpeed: 1200, refreshInterval: 120),
        PanelConfig(name: "leetcode",  streams: ["leetcode"],   typingSpeed: 1200, refreshInterval: 120),
        PanelConfig(name: "words",     streams: ["words"],      typingSpeed: 1200, refreshInterval: 120),
        PanelConfig(name: "iss",       streams: ["iss"],        typingSpeed: 1800, refreshInterval: 15),
        // Row 4 — scrapbook. All hit the same `apis.scraps` endpoint; the
        // process-shared StreamCache guarantees one fetch serves every panel
        // + every display. Optional streams: "places", "concepts", "intake"
        // — swap any into this row or add more rows via config.
        PanelConfig(name: "archive",   streams: ["scraps"],     typingSpeed: 1200, refreshInterval: 300),
        PanelConfig(name: "entities",  streams: ["entities"],   typingSpeed: 1200, refreshInterval: 300),
        PanelConfig(name: "facts",     streams: ["facts"],      typingSpeed: 1000, refreshInterval: 300),
        PanelConfig(name: "trending",  streams: ["trending"],   typingSpeed: 1200, refreshInterval: 300),
        PanelConfig(name: "memory",    streams: ["memory"],     typingSpeed: 1000, refreshInterval: 300),
    ]
}

// MARK: - Loader

/// Config lives at a single canonical path. Inside the screensaver sandbox this
/// resolves to the `legacyScreenSaver` container:
///   ~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/CyberdeckSaver/config.json
///
/// That path is hostile to find — use `make edit-config` from the repo to open
/// it directly. For dev/testing, set `CYBERDECK_CONFIG=/path/to/custom.json`
/// (only propagates to the screensaver via `launchctl setenv` or an LSEnvironment
/// entry in the saver's Info.plist — a plain shell `export` is NOT inherited).
///
/// First run writes defaults so there's always a template to edit.
enum ConfigLoader {
    static func load() -> CyberdeckConfig {
        let fm = FileManager.default
        let decoder = JSONDecoder()

        if let override = ProcessInfo.processInfo.environment["CYBERDECK_CONFIG"],
           fm.isReadableFile(atPath: override) {
            if let cfg = try? decoder.decode(CyberdeckConfig.self, from: Data(contentsOf: URL(fileURLWithPath: override))) {
                Diag.log("Config: loaded from CYBERDECK_CONFIG (\(override))")
                return cfg
            }
        }

        let url = activeConfigURL()
        if fm.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let cfg = try? decoder.decode(CyberdeckConfig.self, from: data) {
                Diag.log("Config: loaded \(cfg.panels.count) panels from \(url.path)")
                return cfg
            }
            Diag.log("Config: parse error at \(url.path) — using defaults")
            return .default
        }

        writeDefaults(to: url)
        Diag.log("Config: wrote defaults to \(url.path)")
        return .default
    }

    static func activeConfigURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("CyberdeckSaver", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    static func writeDefaults(to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(CyberdeckConfig.default) {
            try? data.write(to: url)
        }
    }
}
