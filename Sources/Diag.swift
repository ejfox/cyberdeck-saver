import Foundation

/// Diagnostic logging. Screensavers log to the unified system log; view with:
///   log stream --predicate 'eventMessage CONTAINS "CyberdeckSaver"' --info
///
/// Debug mode is gated by the `CYBERDECK_DEBUG=1` environment variable. A plain
/// shell `export CYBERDECK_DEBUG=1` will NOT reach `legacyScreenSaver`, which is
/// launched by launchd and doesn't inherit the user's shell env. To enable it:
///
///   launchctl setenv CYBERDECK_DEBUG 1
///   killall legacyScreenSaver
///
/// Or add a `LSEnvironment` dict to the .saver's Info.plist.
enum Diag {
    static let enabled: Bool = {
        ProcessInfo.processInfo.environment["CYBERDECK_DEBUG"] == "1"
    }()

    static func log(_ message: @autoclosure () -> String) {
        // Unconditional NSLog for errors/warnings — always on.
        // Debug-only paths call `debug(...)` instead.
        NSLog("CyberdeckSaver: \(message())")
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        NSLog("CyberdeckSaver[DEBUG]: \(message())")
    }
}
