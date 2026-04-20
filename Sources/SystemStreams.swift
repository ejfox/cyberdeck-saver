import AppKit
import Foundation

/// Real-time clock + uptime. Typed instantly so it feels live.
class CommandStream: DataStream {
    let name = "clock"
    func fetch(completion: @escaping (StreamResponse) -> Void) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let time = df.string(from: Date())
        df.dateFormat = "yyyy-MM-dd EEE"
        let date = df.string(from: Date())
        let up = ProcessInfo.processInfo.systemUptime
        let h = Int(up) / 3600
        let m = (Int(up) % 3600) / 60

        let lines: [FormattedLine] = [
            FormattedLine(time, Vulpes.hotPink),
            FormattedLine(date, Vulpes.lightPink),
            FormattedLine("", Vulpes.muted),
            FormattedLine("uptime \(h)h \(m)m", Vulpes.dimPink),
        ]
        completion(StreamResponse(lines: lines, ok: true))
    }
}

/// Host name + OS version + thermal state. Utilitarian like `hostnamectl`/`uname`.
class SystemStream: DataStream {
    let name = "system"
    func fetch(completion: @escaping (StreamResponse) -> Void) {
        let host = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "unknown"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let mem = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        let thermal = ProcessInfo.processInfo.thermalState
        let tStr: String
        let tColor: NSColor
        switch thermal {
        case .nominal:  tStr = "nominal";  tColor = Vulpes.green
        case .fair:     tStr = "fair";     tColor = Vulpes.dimTeal
        case .serious:  tStr = "elevated"; tColor = Vulpes.orange
        case .critical: tStr = "critical"; tColor = Vulpes.hotPink
        @unknown default: tStr = "?";      tColor = Vulpes.muted
        }

        var lines: [FormattedLine] = [
            FormattedLine("host    \(host.lowercased())", Vulpes.teal),
            FormattedLine("darwin  \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", Vulpes.lightPink),
        ]
        #if arch(arm64)
        lines.append(FormattedLine("arch    arm64", Vulpes.lightPink))
        #else
        lines.append(FormattedLine("arch    x86_64", Vulpes.lightPink))
        #endif
        lines.append(contentsOf: [
            FormattedLine("cpu     \(cores) cores", Vulpes.dimPink),
            FormattedLine("mem     \(mem) gb", Vulpes.dimPink),
            FormattedLine("thermal \(tStr)", tColor),
        ])
        completion(StreamResponse(lines: lines, ok: true))
    }
}
