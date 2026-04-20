import AppKit
import QuartzCore

/// Wrapper around `NSView.displayLink(target:selector:)` (macOS 14+), which
/// replaces `NSView.animateOneFrame`. The built-in view loop is unreliable on
/// Sonoma+ — it can skip frames silently and reports stale elapsed-time values.
/// A real CADisplayLink is vsync-locked to the screen's actual refresh rate.
@MainActor
final class DisplayLink {
    private var link: CADisplayLink?
    private let callback: (CFTimeInterval) -> Void
    private var lastTimestamp: CFTimeInterval = 0

    init(view: NSView, _ callback: @escaping (CFTimeInterval) -> Void) {
        self.callback = callback
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func start() {
        lastTimestamp = 0
        link?.isPaused = false
    }

    func stop() {
        link?.isPaused = true
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ sender: CADisplayLink) {
        let now = sender.timestamp
        let dt = lastTimestamp == 0 ? 0 : now - lastTimestamp
        lastTimestamp = now
        // Clamp so wake-from-sleep / long pauses don't fast-forward everything.
        let clamped = Swift.max(0, Swift.min(0.1, dt))
        callback(clamped)
    }

    deinit {
        link?.invalidate()
    }
}
