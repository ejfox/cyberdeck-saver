import ScreenSaver
import Metal
import QuartzCore
import AppKit

/// Sonoma/Sequoia spawn a new `CyberdeckSaverView` every time the screensaver
/// starts, and don't always destroy the previous one. We track live instances
/// weakly so `willstop` can force teardown across the whole process — otherwise
/// the old instances keep a CADisplayLink running and leak Metal textures.
@MainActor
private enum LiveInstances {
    private static var instances: [WeakBox] = []

    static func register(_ view: CyberdeckSaverView) {
        instances = instances.filter { $0.value != nil }
        instances.append(WeakBox(view))
        Diag.debug("LiveInstances: register, count=\(instances.count)")
    }

    static func teardownAll() {
        Diag.debug("LiveInstances: teardownAll, count=\(instances.count)")
        for box in instances {
            box.value?.teardown()
        }
        instances.removeAll()
    }

    private final class WeakBox {
        weak var value: CyberdeckSaverView?
        init(_ v: CyberdeckSaverView) { self.value = v }
    }
}

@objc(CyberdeckSaverView)
class CyberdeckSaverView: ScreenSaverView {
    private var renderer: Renderer?
    private var textEngine: TextEngine?
    private var metalLayer: CAMetalLayer?
    private var device: MTLDevice?
    private var displayLink: DisplayLink?
    private var metalReady = false
    private var torndown = false
    private let config: CyberdeckConfig = ConfigLoader.load()

    // MARK: - Init

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        Diag.log("init frame=\(frame) isPreview=\(isPreview) debug=\(Diag.enabled)")

        // The built-in ScreenSaverView frame loop is unreliable on Sonoma+.
        // We turn it way down (it still ticks for fallback draw) and run our
        // own CADisplayLink instead.
        animationTimeInterval = 1.0

        setupMetal()

        LiveInstances.register(self)

        // Sonoma+ workaround: stopAnimation() is often never called, and the
        // `legacyScreenSaver` host process can keep sampling Metal textures
        // from dead views. The distributed notification is our real signal
        // that the screensaver is ending.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screensaverWillStop(_:)),
            name: NSNotification.Name("com.apple.screensaver.willstop"),
            object: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private func setupMetal() {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            Diag.log("No Metal device — using fallback rendering")
            return
        }
        self.device = dev
        Diag.log("Metal device: \(dev.name)")

        wantsLayer = true

        let ml = CAMetalLayer()
        ml.device = dev
        ml.pixelFormat = .bgra8Unorm
        ml.framebufferOnly = false
        ml.frame = bounds
        ml.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        ml.drawableSize = CGSize(
            width: max(1, bounds.width * ml.contentsScale),
            height: max(1, bounds.height * ml.contentsScale))
        self.layer = ml
        self.metalLayer = ml

        let bundle = Bundle(for: type(of: self))
        Diag.debug("Bundle path: \(bundle.bundlePath)")

        guard let r = Renderer(device: dev, bundle: bundle, config: config) else {
            Diag.log("Failed to create renderer — using fallback")
            return
        }
        self.renderer = r
        r.resize(to: ml.drawableSize)

        let te = TextEngine(device: dev, size: bounds.size, scale: ml.contentsScale,
                            config: config, isPreview: isPreview)
        self.textEngine = te

        metalReady = true
        Diag.log("Metal setup complete")
    }

    // MARK: - ScreenSaverView lifecycle

    override func startAnimation() {
        super.startAnimation()
        Diag.log("startAnimation")
        textEngine?.start()
        startDisplayLink()
    }

    override func stopAnimation() {
        Diag.log("stopAnimation")
        textEngine?.stop()
        displayLink?.stop()
        super.stopAnimation()
    }

    @objc private func screensaverWillStop(_ notification: Notification) {
        Diag.log("willStop notification")
        LiveInstances.teardownAll()
        // legacyScreenSaver sometimes keeps its Metal context warm after we
        // release ours, which leads to texture corruption on the next run.
        // A clean exit(0) is the only reliable way to reset state.
        exit(0)
    }

    /// Release all GPU/CPU resources. Safe to call multiple times.
    /// Invoked from `willstop` + on deinit — idempotent.
    func teardown() {
        guard !torndown else { return }
        torndown = true
        Diag.debug("teardown")
        displayLink?.invalidate()
        displayLink = nil
        textEngine?.stop()
        textEngine = nil
        renderer = nil
        metalLayer = nil
        device = nil
        metalReady = false
    }

    // MARK: - Rendering

    private func startDisplayLink() {
        if displayLink == nil {
            displayLink = DisplayLink(view: self) { [weak self] dt in
                self?.renderTick(dt: dt)
            }
        }
        displayLink?.start()
    }

    private func renderTick(dt: CFTimeInterval) {
        PerfMonitor.shared.frameTick()
        guard metalReady,
              let ml = metalLayer,
              let drawable = ml.nextDrawable(),
              let renderer = renderer,
              let textEngine = textEngine else {
            if !metalReady { setNeedsDisplay(bounds) }
            return
        }
        textEngine.update(dt: dt)
        renderer.render(textEngine: textEngine, to: drawable)
    }

    // ScreenSaverView still calls this on its own cadence — we defer to the
    // display link for rendering. This hook only handles the pre-Metal fallback.
    override func animateOneFrame() {
        if !metalReady {
            setNeedsDisplay(bounds)
        }
    }

    // Fallback: plain Core Graphics rendering if Metal fails.
    override func draw(_ rect: NSRect) {
        guard !metalReady else { return }

        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx?.fill(bounds)

        let text = "[CYBERDECK] Metal unavailable — fallback mode" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
            .foregroundColor: NSColor(red: 0.902, green: 0, blue: 0.404, alpha: 1)
        ]
        text.draw(at: CGPoint(x: 40, y: bounds.height - 60), withAttributes: attrs)
    }

    // MARK: - Layout

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateLayerSize()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        updateLayerSize()
    }

    private func updateLayerSize() {
        guard let ml = metalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        ml.frame = bounds
        ml.contentsScale = scale
        ml.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale))

        renderer?.resize(to: ml.drawableSize)
        textEngine?.resize(to: bounds.size, scale: scale)
    }

    // MARK: - Config

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
