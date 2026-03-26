import ScreenSaver
import Metal
import QuartzCore
import AppKit

@objc(CyberdeckSaverView)
class CyberdeckSaverView: ScreenSaverView {
    private var renderer: Renderer?
    private var textEngine: TextEngine?
    private var metalLayer: CAMetalLayer?
    private var device: MTLDevice?
    private var metalReady = false

    // MARK: - Init

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        NSLog("CyberdeckSaver: init frame=\(frame) isPreview=\(isPreview)")
        animationTimeInterval = 1.0 / 60.0

        // Don't return nil — always create the view, even if Metal fails.
        // We'll fall back to Core Graphics drawing if Metal isn't available.
        setupMetal()

        // Sonoma+ workaround: stopAnimation() is never called,
        // so listen for the distributed notification instead
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
            NSLog("CyberdeckSaver: No Metal device — will use fallback rendering")
            return
        }
        self.device = dev
        NSLog("CyberdeckSaver: Metal device: \(dev.name)")

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
        NSLog("CyberdeckSaver: Bundle path: \(bundle.bundlePath)")
        NSLog("CyberdeckSaver: Resource path: \(bundle.resourcePath ?? "nil")")

        if let metallib = bundle.url(forResource: "default", withExtension: "metallib") {
            NSLog("CyberdeckSaver: Found metallib at \(metallib.path)")
        } else {
            NSLog("CyberdeckSaver: WARNING — default.metallib not found in bundle resources!")
        }

        guard let r = Renderer(device: dev, bundle: bundle) else {
            NSLog("CyberdeckSaver: Failed to create renderer — will use fallback")
            return
        }
        self.renderer = r
        r.resize(to: ml.drawableSize)
        animationTimeInterval = r.recommendedInterval

        let te = TextEngine(device: dev, size: bounds.size, scale: ml.contentsScale)
        self.textEngine = te

        metalReady = true
        NSLog("CyberdeckSaver: Metal setup complete")
    }

    // MARK: - ScreenSaverView lifecycle

    override func startAnimation() {
        super.startAnimation()
        NSLog("CyberdeckSaver: startAnimation")
        textEngine?.start()
    }

    override func stopAnimation() {
        NSLog("CyberdeckSaver: stopAnimation")
        textEngine?.stop()
        super.stopAnimation()
    }

    @objc private func screensaverWillStop(_ notification: Notification) {
        NSLog("CyberdeckSaver: willStop notification")
        textEngine?.stop()
    }

    // MARK: - Rendering

    override func animateOneFrame() {
        if metalReady {
            renderMetal()
        } else {
            setNeedsDisplay(bounds)
        }
    }

    private func renderMetal() {
        guard let ml = metalLayer,
              let drawable = ml.nextDrawable(),
              let renderer = renderer,
              let textEngine = textEngine else { return }

        textEngine.update(dt: animationTimeInterval)
        renderer.render(textEngine: textEngine, to: drawable)
    }

    // Fallback: plain Core Graphics rendering if Metal fails
    override func draw(_ rect: NSRect) {
        guard !metalReady else { return }

        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx?.fill(bounds)

        let text = "[CYBERDECK] Initializing..." as NSString
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
