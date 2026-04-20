import AppKit

// MARK: - Vulpes Palette
// Matches EJ's Ghostty terminal theme. Hot pink is the only bloom-active color.

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

// MARK: - Formatted line

struct FormattedLine {
    let text: String
    let color: NSColor

    init(_ text: String, _ color: NSColor) {
        self.text = text
        self.color = color
    }
}

// MARK: - Formatting helpers

/// Progress bar. `value` is normalized to `max` (e.g. bar(8, max: 12) = 8/12 filled).
func bar(_ value: Double, max: Double, width: Int = 10) -> String {
    let pct = Swift.max(0, Swift.min(1, value / max))
    let filled = Int(pct * Double(width))
    let empty = width - filled
    return String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: empty)
}

/// Word-wrap a string to a max column width. Drops empty results.
func wrapText(_ text: String, width: Int) -> [String] {
    guard !text.isEmpty, width > 0 else { return [] }
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

/// Extract a stringified value from a JSON dict, defaulting to an em-dash.
func str(_ dict: Any?, _ key: String) -> String {
    guard let d = dict as? [String: Any], let v = d[key] else { return "\u{2014}" }
    return "\(v)"
}

// MARK: - Stream protocol

enum FetchError {
    case offline
    case httpError(Int)
    case parseError
    case badUrl

    var label: String {
        switch self {
        case .offline:             return "OFFLINE"
        case .httpError(let code): return "HTTP \(code)"
        case .parseError:          return "BAD DATA"
        case .badUrl:              return "BAD URL"
        }
    }
}

struct StreamResponse {
    let lines: [FormattedLine]
    let ok: Bool
}

protocol DataStream {
    var name: String { get }
    func fetch(completion: @escaping (StreamResponse) -> Void)
    /// Data shown in System Settings preview thumbnails and anywhere else we
    /// want a plausible-looking snapshot without hitting the network. Streams
    /// get a sensible default but should override with plausible canned lines.
    var previewResponse: StreamResponse { get }
}

extension DataStream {
    var previewResponse: StreamResponse {
        StreamResponse(lines: [FormattedLine(name, Vulpes.teal)], ok: true)
    }
}
