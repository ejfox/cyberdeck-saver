import AppKit
import Foundation

// EJ's VPS OSINT tools. These are his real projects — we keep the project names
// as-is (skywatch, anomalywatch, briefings) since they're the actual services.

class SkywatchStream: DataStream {
    let name = "skywatch"
    let url: String
    init(url: String) { self.url = url }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("skywatch.tools.ejfox.com", Vulpes.teal),
            FormattedLine("today     1247 flights", Vulpes.lightPink),
            FormattedLine("military  3 tracked", Vulpes.hotPink),
            FormattedLine("total db  134852", Vulpes.dimPink),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(
            url: url,
            timeout: 20,
            header: "skywatch.tools.ejfox.com",
            build: { json in
                var lines: [FormattedLine] = []
                guard let d = json as? [String: Any] else { return lines }
                lines.append(FormattedLine("today     \(d["today"] ?? "?") flights", Vulpes.lightPink))
                lines.append(FormattedLine("military  \(d["military"] ?? "?") tracked", Vulpes.hotPink))
                lines.append(FormattedLine("total db  \(d["total"] ?? "?")", Vulpes.dimPink))
                return lines
            },
            completion: completion)
    }
}

class AnomalywatchStream: DataStream {
    let name = "anomaly"
    let url: String
    init(url: String) { self.url = url }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("anomalywatch.tools.ejfox.com", Vulpes.teal),
            FormattedLine("signals      8237", Vulpes.lightPink),
            FormattedLine("alerts       12", Vulpes.dimPink),
            FormattedLine("active cases 4", Vulpes.hotPink),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(
            url: url,
            timeout: 20,
            header: "anomalywatch.tools.ejfox.com",
            build: { json in
                var lines: [FormattedLine] = []
                guard let d = json as? [String: Any] else { return lines }
                lines.append(FormattedLine("signals      \(d["signals"] ?? "?")", Vulpes.lightPink))
                lines.append(FormattedLine("alerts       \(d["incoming_alerts"] ?? "?")", Vulpes.dimPink))
                lines.append(FormattedLine("active cases \(d["active_investigations"] ?? "?")", Vulpes.hotPink))
                return lines
            },
            completion: completion)
    }
}

class BriefingsStream: DataStream {
    let name = "briefings"
    let url: String
    init(url: String) { self.url = url }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("briefings.tools.ejfox.com", Vulpes.teal),
            FormattedLine("2026-04-19", Vulpes.mutedMagenta),
            FormattedLine("  hudson valley weekly", Vulpes.lightPink),
            FormattedLine("  pattern analysis", Vulpes.lightPink),
            FormattedLine("2026-04-18", Vulpes.mutedMagenta),
            FormattedLine("  central hudson filings", Vulpes.lightPink),
            FormattedLine("2026-04-17", Vulpes.mutedMagenta),
            FormattedLine("  local governance", Vulpes.lightPink),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(
            url: url,
            timeout: 20,
            header: "briefings.tools.ejfox.com",
            build: { json in
                var lines: [FormattedLine] = []
                guard let reports = json as? [[String: Any]] else {
                    lines.append(FormattedLine("no reports", Vulpes.muted))
                    return lines
                }
                for report in reports.prefix(5) {
                    let date = String((report["date"] as? String ?? "").prefix(10))
                    let title = report["title"] as? String ?? "untitled"
                    lines.append(FormattedLine(date, Vulpes.mutedMagenta))
                    for chunk in wrapText(title, width: 34).prefix(2) {
                        lines.append(FormattedLine("  \(chunk)", Vulpes.lightPink))
                    }
                }
                return lines
            },
            completion: completion)
    }
}
