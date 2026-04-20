import AppKit
import Foundation

/// Great-circle distance in miles (haversine).
private func haversineMiles(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let R = 3958.8
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
        + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
        * sin(dLon / 2) * sin(dLon / 2)
    return 2 * R * atan2(sqrt(a), sqrt(1 - a))
}

// MARK: - USGS earthquakes (2.5+, last 24h)

class SeismicStream: DataStream {
    let name = "usgs"

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("earthquake.usgs.gov", Vulpes.teal),
            FormattedLine("events 24h  42", Vulpes.lightPink),
            FormattedLine("", Vulpes.muted),
            FormattedLine("m5.4", Vulpes.hotPink),
            FormattedLine("  near kyushu, japan", Vulpes.dimPink),
            FormattedLine("m4.2", Vulpes.orange),
            FormattedLine("  central alaska", Vulpes.dimPink),
            FormattedLine("m3.8", Vulpes.lightPink),
            FormattedLine("  northern california", Vulpes.dimPink),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(
            url: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_day.geojson",
            timeout: 15,
            header: "earthquake.usgs.gov",
            build: { json in
                var lines: [FormattedLine] = []
                guard let d = json as? [String: Any],
                      let meta = d["metadata"] as? [String: Any],
                      let features = d["features"] as? [[String: Any]] else {
                    return lines
                }
                let count = (meta["count"] as? Int) ?? features.count
                lines.append(FormattedLine("events 24h  \(count)", Vulpes.lightPink))
                lines.append(FormattedLine("", Vulpes.muted))

                let sorted = features.sorted { a, b in
                    let am = (a["properties"] as? [String: Any])?["mag"] as? Double ?? 0
                    let bm = (b["properties"] as? [String: Any])?["mag"] as? Double ?? 0
                    return am > bm
                }
                for event in sorted.prefix(4) {
                    let props = event["properties"] as? [String: Any]
                    let mag = props?["mag"] as? Double ?? 0
                    let place = (props?["place"] as? String ?? "?").lowercased()
                    let color: NSColor = mag >= 5 ? Vulpes.hotPink
                        : mag >= 4 ? Vulpes.orange
                        : Vulpes.lightPink
                    lines.append(FormattedLine("m\(String(format: "%.1f", mag))", color))
                    for chunk in wrapText(place, width: 32).prefix(2) {
                        lines.append(FormattedLine("  \(chunk)", Vulpes.dimPink))
                    }
                }
                return lines
            },
            completion: completion)
    }
}

// MARK: - NOAA SWPC planetary K-index

class SolarStream: DataStream {
    let name = "solar"

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("swpc.noaa.gov", Vulpes.teal),
            FormattedLine("geomag     quiet", Vulpes.green),
            FormattedLine("kp index   2.3 \(bar(2.3, max: 9))", Vulpes.lightPink),
            FormattedLine("", Vulpes.muted),
            FormattedLine("samples    24", Vulpes.dimPink),
            FormattedLine("updated    2026-04-20 14:00z", Vulpes.muted),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(
            url: "https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json",
            timeout: 15,
            header: "swpc.noaa.gov",
            build: { json in
                var lines: [FormattedLine] = []
                // Response is [[headers...], [row...], ...]. Columns: time_tag, Kp, a_running, station_count.
                guard let rows = json as? [[Any]], rows.count > 1 else { return lines }
                let recent = rows.dropFirst().suffix(1).first
                let kpStr = recent?[1] as? String ?? "\(recent?[1] ?? 0)"
                let kp = Double(kpStr) ?? 0

                let stormLabel: String
                let stormColor: NSColor
                switch kp {
                case ..<4:   stormLabel = "quiet";      stormColor = Vulpes.green
                case 4..<5:  stormLabel = "unsettled";  stormColor = Vulpes.dimTeal
                case 5..<6:  stormLabel = "g1 minor";   stormColor = Vulpes.orange
                case 6..<7:  stormLabel = "g2 moderate";stormColor = Vulpes.orange
                case 7..<8:  stormLabel = "g3 strong";  stormColor = Vulpes.hotPink
                case 8..<9:  stormLabel = "g4 severe";  stormColor = Vulpes.hotPink
                default:     stormLabel = "g5 extreme"; stormColor = Vulpes.hotPink
                }

                lines.append(FormattedLine("geomag     \(stormLabel)", stormColor))
                lines.append(FormattedLine("kp index   \(String(format: "%.1f", kp)) \(bar(kp, max: 9))", Vulpes.lightPink))
                lines.append(FormattedLine("", Vulpes.muted))
                lines.append(FormattedLine("samples    \(rows.count - 1)", Vulpes.dimPink))
                if let t = recent?[0] as? String {
                    let short = String(t.prefix(16)).replacingOccurrences(of: "T", with: " ")
                    lines.append(FormattedLine("updated    \(short)z", Vulpes.muted))
                }
                return lines
            },
            completion: completion)
    }
}

// MARK: - ISS position

class ISSStream: DataStream {
    let name = "iss"
    let observerLat: Double
    let observerLon: Double

    init(lat: Double, lon: Double) {
        self.observerLat = lat
        self.observerLon = lon
    }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("iss (25544)", Vulpes.teal),
            FormattedLine("tracking \u{25CF}", Vulpes.green),
            FormattedLine("", Vulpes.muted),
            FormattedLine("lat    +23.45", Vulpes.lightPink),
            FormattedLine("lon    -158.72", Vulpes.lightPink),
            FormattedLine("alt    408 km", Vulpes.dimPink),
            FormattedLine("vel    27580 km/h", Vulpes.dimPink),
            FormattedLine("dist   4821 mi", Vulpes.muted),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(
            url: "https://api.wheretheiss.at/v1/satellites/25544",
            timeout: 10,
            header: "iss (25544)",
            build: { [observerLat, observerLon] json in
                var lines: [FormattedLine] = []
                guard let d = json as? [String: Any] else { return lines }
                let lat = d["latitude"] as? Double ?? 0
                let lon = d["longitude"] as? Double ?? 0
                let alt = d["altitude"] as? Double ?? 0
                let vel = d["velocity"] as? Double ?? 0
                let dist = haversineMiles(lat1: observerLat, lon1: observerLon, lat2: lat, lon2: lon)
                let overhead = dist < 500

                lines.append(FormattedLine(overhead ? "overhead \u{25B2}" : "tracking \u{25CF}",
                                           overhead ? Vulpes.hotPink : Vulpes.green))
                lines.append(FormattedLine("", Vulpes.muted))
                lines.append(FormattedLine("lat    \(String(format: "%+.2f", lat))", Vulpes.lightPink))
                lines.append(FormattedLine("lon    \(String(format: "%+.2f", lon))", Vulpes.lightPink))
                lines.append(FormattedLine("alt    \(String(format: "%.0f", alt)) km", Vulpes.dimPink))
                lines.append(FormattedLine("vel    \(String(format: "%.0f", vel)) km/h", Vulpes.dimPink))
                lines.append(FormattedLine("dist   \(String(format: "%.0f", dist)) mi", Vulpes.muted))
                return lines
            },
            completion: completion)
    }
}

// MARK: - URLhaus (abuse.ch) — recent malicious URLs

class ThreatStream: DataStream {
    let name = "urlhaus"

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("urlhaus.abuse.ch", Vulpes.teal),
            FormattedLine("entries  4832", Vulpes.lightPink),
            FormattedLine("", Vulpes.muted),
            FormattedLine("malware_download", Vulpes.hotPink),
            FormattedLine("  194.26.29.42", Vulpes.dimPink),
            FormattedLine("exploit_kit", Vulpes.hotPink),
            FormattedLine("  phish.example.ru", Vulpes.dimPink),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        ApiClient.fetchAndFormat(
            url: "https://urlhaus.abuse.ch/downloads/json_recent/",
            timeout: 20,
            header: "urlhaus.abuse.ch",
            build: { json in
                var lines: [FormattedLine] = []
                guard let d = json as? [String: Any] else { return lines }

                var entries: [[String: Any]] = []
                for (_, value) in d {
                    if let arr = value as? [[String: Any]], let first = arr.first {
                        entries.append(first)
                    }
                }
                entries.sort { a, b in
                    (a["dateadded"] as? String ?? "") > (b["dateadded"] as? String ?? "")
                }

                lines.append(FormattedLine("entries  \(d.count)", Vulpes.lightPink))
                lines.append(FormattedLine("", Vulpes.muted))

                for entry in entries.prefix(3) {
                    let threat = (entry["threat"] as? String ?? "?").lowercased()
                    let url = entry["url"] as? String ?? "?"
                    let host = URL(string: url)?.host ?? String(url.prefix(30))
                    lines.append(FormattedLine(threat, Vulpes.hotPink))
                    lines.append(FormattedLine("  \(host.prefix(34))", Vulpes.dimPink))
                }
                return lines
            },
            completion: completion)
    }
}

// MARK: - OpenSky Network — live aircraft in bbox

class AirspaceStream: DataStream {
    let name = "ads-b"
    let bbox: AirspaceConfig

    init(bbox: AirspaceConfig) {
        self.bbox = bbox
    }

    var previewResponse: StreamResponse {
        StreamResponse(lines: [
            FormattedLine("opensky-network.org", Vulpes.teal),
            FormattedLine("contacts  12", Vulpes.lightPink),
            FormattedLine("", Vulpes.muted),
            FormattedLine("jbu1234  35000ft 428kt", Vulpes.dimPink),
            FormattedLine("aal2847  39000ft 441kt", Vulpes.dimPink),
            FormattedLine("n472ww   8500ft 189kt", Vulpes.dimPink),
            FormattedLine("dal891   37000ft 465kt", Vulpes.dimPink),
        ], ok: true)
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        let url = "https://opensky-network.org/api/states/all?" +
            "lamin=\(bbox.minLat)&lamax=\(bbox.maxLat)&lomin=\(bbox.minLon)&lomax=\(bbox.maxLon)"
        ApiClient.fetchAndFormat(
            url: url,
            timeout: 20,
            header: "opensky-network.org",
            build: { json in
                var lines: [FormattedLine] = []
                guard let d = json as? [String: Any],
                      let states = d["states"] as? [[Any?]] else {
                    lines.append(FormattedLine("no contacts", Vulpes.muted))
                    return lines
                }
                lines.append(FormattedLine("contacts  \(states.count)", Vulpes.lightPink))
                lines.append(FormattedLine("", Vulpes.muted))

                // State vector: [icao24, callsign, origin, ..., lon(5), lat(6), baro_alt(7),
                // on_ground(8), velocity(9), ...]
                let flying = states.filter { ($0.count > 8) && (($0[8] as? Bool) != true) }
                for s in flying.prefix(4) {
                    let callsign = (s.count > 1 ? s[1] as? String : nil)?
                        .trimmingCharacters(in: .whitespaces) ?? "?"
                    let alt = s.count > 7 ? (s[7] as? Double ?? 0) : 0
                    let vel = s.count > 9 ? (s[9] as? Double ?? 0) : 0
                    let ft = Int(alt * 3.281 / 100) * 100
                    let kts = Int(vel * 1.944)
                    let cs = (callsign.isEmpty ? "?" : callsign).lowercased()
                    lines.append(FormattedLine("\(cs.padding(toLength: 8, withPad: " ", startingAt: 0)) \(ft)ft \(kts)kt", Vulpes.dimPink))
                }
                return lines
            },
            completion: completion)
    }
}
