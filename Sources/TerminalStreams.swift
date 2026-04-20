import AppKit
import Foundation

// MARK: - ANSI stripping + formatting

/// Strip ANSI CSI sequences (colors, cursor positioning, etc.) from a string.
/// We intentionally discard color info — terminal output is rendered in our
/// own palette to stay visually consistent with the rest of the screensaver.
private let ansiRegex: NSRegularExpression? = {
    try? NSRegularExpression(
        pattern: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
        options: [])
}()

fileprivate func stripAnsi(_ s: String) -> String {
    guard let r = ansiRegex else { return s }
    let range = NSRange(s.startIndex..., in: s)
    return r.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
}

/// Colorize lines with a simple heuristic — teal for lines starting with
/// uppercase (headers/fields), light pink for lines starting with a digit,
/// dim pink otherwise. Keeps the vulpes palette without parsing SGR.
fileprivate func formatTerminalOutput(_ raw: String, maxCols: Int) -> [FormattedLine] {
    let cleaned = stripAnsi(raw)
    var result: [FormattedLine] = []
    for line in cleaned.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = String(line.prefix(maxCols))
        if trimmed.isEmpty {
            result.append(FormattedLine("", Vulpes.muted))
            continue
        }
        let first = trimmed.first
        let color: NSColor
        if first?.isNumber == true {
            color = Vulpes.lightPink
        } else if first?.isUppercase == true {
            color = Vulpes.teal
        } else {
            color = Vulpes.dimPink
        }
        result.append(FormattedLine(trimmed, color))
    }
    return result
}

// MARK: - ShellStream — runs a local command

/// Runs a local shell command, captures stdout, renders the last N lines.
/// Screensavers run inside `legacyScreenSaver`, which is sandboxed on recent
/// macOS versions — so only system binaries with no elevated permissions
/// (e.g. `/usr/bin/top`, `/bin/ps`, `/usr/bin/uptime`) are guaranteed to work.
class ShellStream: DataStream {
    let name: String
    let path: String
    let args: [String]
    let maxLines: Int
    let maxCols: Int

    init(label: String, path: String, args: [String], maxLines: Int = 12, maxCols: Int = 40) {
        self.name = label
        self.path = path
        self.args = args
        self.maxLines = maxLines
        self.maxCols = maxCols
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        let path = self.path, args = self.args, maxCols = self.maxCols, maxLines = self.maxLines, name = self.name
        DispatchQueue.global(qos: .utility).async {
            let response = ShellStream.run(path: path, args: args, name: name, maxCols: maxCols, maxLines: maxLines)
            DispatchQueue.main.async { completion(response) }
        }
    }

    private static func run(path: String, args: [String], name: String, maxCols: Int, maxLines: Int) -> StreamResponse {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            Diag.log("ShellStream: failed to run \(path): \(error)")
            return StreamResponse(lines: [
                FormattedLine(path, Vulpes.orange),
                FormattedLine("failed to run", Vulpes.muted),
            ], ok: false)
        }

        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return StreamResponse(lines: [
                FormattedLine(path, Vulpes.orange),
                FormattedLine("timeout", Vulpes.muted),
            ], ok: false)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let all = formatTerminalOutput(output, maxCols: maxCols)
        let head = [FormattedLine(name, Vulpes.teal)]
        let tail = Array(all.suffix(maxLines))
        return StreamResponse(lines: head + tail, ok: true)
    }
}

// MARK: - TerminalStream — polls a URL for plain-text terminal output

/// Fetches a URL expected to return plain text and renders it. Pair with a
/// simple server-side endpoint like:
///
///   # flask example
///   @app.route("/top")
///   def top(): return subprocess.check_output(["top", "-b", "-n", "1"])
///
/// Or expose anything else you want: `btop --batch`, `ss -tnp`, `docker stats`.
class TerminalStream: DataStream {
    let name: String
    let url: String
    let maxLines: Int
    let maxCols: Int

    init(label: String, url: String, maxLines: Int = 12, maxCols: Int = 40) {
        self.name = label
        self.url = url
        self.maxLines = maxLines
        self.maxCols = maxCols
    }

    func fetch(completion: @escaping (StreamResponse) -> Void) {
        guard let target = URL(string: url) else {
            completion(StreamResponse(lines: [
                FormattedLine(name, Vulpes.orange),
                FormattedLine("bad url", Vulpes.muted),
            ], ok: false))
            return
        }
        var req = URLRequest(url: target)
        req.timeoutInterval = 15

        ApiClient.session.dataTask(with: req) { [name, maxCols, maxLines] data, response, error in
            let offline = StreamResponse(lines: [
                FormattedLine(name, Vulpes.orange),
                FormattedLine("offline", Vulpes.muted),
            ], ok: false)
            if error != nil || data == nil {
                DispatchQueue.main.async { completion(offline) }
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                DispatchQueue.main.async {
                    completion(StreamResponse(lines: [
                        FormattedLine(name, Vulpes.orange),
                        FormattedLine("http \(http.statusCode)", Vulpes.muted),
                    ], ok: false))
                }
                return
            }
            let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let all = formatTerminalOutput(text, maxCols: maxCols)
            let head = [FormattedLine(name, Vulpes.teal)]
            let tail = Array(all.suffix(maxLines))
            DispatchQueue.main.async {
                completion(StreamResponse(lines: head + tail, ok: true))
            }
        }.resume()
    }
}
