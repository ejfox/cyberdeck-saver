import AppKit
import Metal
import CoreText

struct Panel {
    let name: String
    let streams: [DataStream]       // rotation — index 0 is the initial active stream
    let typingSpeed: Double
    let refreshInterval: TimeInterval
    let rotationInterval: TimeInterval

    var origin: (col: Int, row: Int) = (0, 0)
    var size: (cols: Int, rows: Int) = (0, 0)

    var activeStream: Int = 0
    var timeOnCurrentStream: Double = 0

    var lines: [FormattedLine] = []
    var revealedChars: Int = 0
    var totalChars: Int = 0
    var typingAccumulator: Double = 0
    var lastFetchTime: Date = .distantPast
    var lastFetchOK: Bool = true
    var isFetching: Bool = false
    var startDelay: Double = 0
    var age: Double = 0

    /// Fade alpha during rotation swap. 1.0 at rest, ramps down/up around swaps.
    var fadeAlpha: Double = 1.0

    /// Per-panel dirty flag. Only re-rasterized when this is set, so idle
    /// panels don't burn CPU on every frame. The renderer clears and redraws
    /// just this panel's rect, preserving other panels' pixels from prior frames.
    var dirty: Bool = true

    /// For idle-cursor pulse bookkeeping — we mark the panel dirty at ~12Hz
    /// when it's sitting idle so the pulsing cursor actually animates on screen.
    var lastIdlePulseTick: Double = 0

    var currentStream: DataStream {
        streams[activeStream % max(1, streams.count)]
    }
}

class TextEngine {
    let device: MTLDevice

    // Double-buffered text textures. CPU writes to index `writeIndex`;
    // GPU reads whichever one was most recently handed to the renderer.
    private var textures: [MTLTexture] = []
    private var writeIndex: Int = 0
    private(set) var currentTextureIndex: Int = 0
    var currentTexture: MTLTexture? {
        textures.isEmpty ? nil : textures[currentTextureIndex]
    }

    private var bitmapData: UnsafeMutableRawPointer?
    private var cgContext: CGContext?
    private var nsContext: NSGraphicsContext?
    private var panels: [Panel] = []
    private var font: NSFont
    private var cellSize: CGSize
    private var layout: PanelLayout = PanelLayout.forPanelCount(1, gridCols: 1, gridRows: 1)
    private var pointSize: CGSize = .zero
    private var pixelWidth: Int = 0
    private var pixelHeight: Int = 0
    private var scale: CGFloat = 2.0
    private var bytesPerRow: Int = 0
    private var started = false

    // Minimum retry interval after a failed fetch — so a transient network hiccup
    // doesn't leave a panel stale for the full refresh interval.
    private let failedRetryInterval: TimeInterval = 30

    // Throttle expensive Core Text redraws. The display link still ticks at vsync
    // for the Metal post-processing (scanline flicker needs ~60Hz to look smooth),
    // but the CPU-side text rasterization is capped here. Configurable via
    // `render.textRedrawHz` in the config file.
    private var lastCTRedraw: CFTimeInterval = 0
    private var minCTInterval: TimeInterval { 1.0 / max(1.0, config.render.textRedrawHz) }

    /// True when running as a System Settings thumbnail preview. In this mode we
    /// never hit the network — every stream's `previewResponse` is injected as
    /// the one-and-only fetch. Animations still run fully so the preview looks
    /// alive, not static.
    private let isPreview: Bool

    init(device: MTLDevice, size: CGSize, scale: CGFloat, config: CyberdeckConfig, isPreview: Bool = false) {
        self.device = device
        self.scale = scale
        self.config = config
        self.isPreview = isPreview

        let fontSize = CGFloat(config.render.fontSize)
        self.font = NSFont(name: "MonaspiceKrNFM-Regular", size: fontSize)
            ?? NSFont(name: "Menlo-Regular", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        self.cellSize = NSString(string: "M").size(withAttributes: attrs)

        setupPanels()
        resize(to: size, scale: scale)
    }

    private let config: CyberdeckConfig

    private func setupPanels() {
        panels = config.panels.compactMap { pc -> Panel? in
            let streams = pc.streams.compactMap { StreamFactory.make($0, config: config) }
            guard !streams.isEmpty else {
                Diag.log("Panel '\(pc.name)' has no valid streams; skipping")
                return nil
            }
            return Panel(
                name: pc.name,
                streams: streams,
                typingSpeed: pc.typingSpeed,
                refreshInterval: pc.refreshInterval,
                rotationInterval: pc.rotationInterval
            )
        }
        Diag.log("TextEngine: \(panels.count) panels loaded")
    }

    func resize(to size: CGSize, scale: CGFloat) {
        self.pointSize = size
        self.scale = scale
        pixelWidth = max(1, Int(size.width * scale))
        pixelHeight = max(1, Int(size.height * scale))

        let gridCols = max(1, Int(size.width / cellSize.width))
        let gridRows = max(1, Int(size.height / cellSize.height))
        layout = PanelLayout.forPanelCount(panels.count, gridCols: gridCols, gridRows: gridRows)

        bytesPerRow = pixelWidth * 4
        let totalBytes = bytesPerRow * pixelHeight
        bitmapData?.deallocate()
        bitmapData = UnsafeMutableRawPointer.allocate(byteCount: totalBytes, alignment: 16)
        memset(bitmapData!, 0, totalBytes)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        cgContext = CGContext(
            data: bitmapData!, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo)
        cgContext?.translateBy(x: 0, y: CGFloat(pixelHeight))
        cgContext?.scaleBy(x: scale, y: -scale)
        if let cg = cgContext {
            nsContext = NSGraphicsContext(cgContext: cg, flipped: true)
        }

        // Double-buffer: two shared-storage textures so the CPU can write one
        // while the GPU samples the other.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: pixelWidth, height: pixelHeight, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        textures = [
            device.makeTexture(descriptor: desc),
            device.makeTexture(descriptor: desc),
        ].compactMap { $0 }
        writeIndex = 0
        currentTextureIndex = 0

        layoutPanels()
        for i in panels.indices { panels[i].dirty = true }
    }

    private func layoutPanels() {
        for i in panels.indices {
            let rect = layout.rect(forIndex: i)
            panels[i].origin = rect.origin
            panels[i].size = rect.size
        }
    }

    func start() {
        started = true
        // Stagger panel startups + force a fresh fetch on resume-from-sleep.
        // Rotations are also staggered so they don't all swap at once.
        for i in panels.indices {
            panels[i].startDelay = Double(i) * 0.4 + Double.random(in: 0...1.5)
            panels[i].age = 0
            panels[i].lastFetchTime = .distantPast
            panels[i].activeStream = 0
            // 2s stagger between slots, wrapped so nobody's "past due" at start.
            // Parens matter: method binding is tighter than `*`, so the naked
            // `Double(i) * 2.0.truncatingRemainder(...)` would compute 2%rotInterval
            // first (effectively a no-op) and then multiply.
            panels[i].timeOnCurrentStream = (Double(i) * 2.0)
                .truncatingRemainder(dividingBy: max(0.1, panels[i].rotationInterval))
            panels[i].fadeAlpha = 1.0
        }
    }

    func stop() {
        started = false
    }

    /// Fade transition duration at each rotation boundary (seconds).
    private let rotationFadeDuration: Double = 0.5

    /// Idle pulse redraw rate — how often an idle panel is marked dirty so its
    /// pulsing cursor can animate on screen. 12Hz reads as smooth and keeps CPU
    /// cost modest (20 panels × 12Hz worst-case = 240 panel-draws/sec).
    private let idlePulseHz: Double = 12.0

    /// Spinner tick rate. The braille wheel only has 8 frames; anything above
    /// 10Hz is invisible wasted work. Gated exactly like the idle pulse.
    private let spinnerHz: Double = 10.0
    private var lastSpinnerTick: Double = 0

    func update(dt: TimeInterval) {
        guard started else { return }

        let now = Date()
        let nowMono = CACurrentMediaTime()

        // Drive typing jitter — same phase for all panels, slightly different per
        // character via a fast hash. Gives typed text a human-ish feel.
        for i in panels.indices {
            panels[i].age += dt
            guard panels[i].age > panels[i].startDelay else { continue }

            // Rotation — only if the slot has >1 stream and rotationInterval > 0.
            if panels[i].streams.count > 1 && panels[i].rotationInterval > 0 {
                panels[i].timeOnCurrentStream += dt
                let t = panels[i].timeOnCurrentStream
                let interval = panels[i].rotationInterval

                if t >= interval {
                    panels[i].activeStream = (panels[i].activeStream + 1) % panels[i].streams.count
                    panels[i].timeOnCurrentStream = 0
                    panels[i].lastFetchTime = .distantPast
                    panels[i].revealedChars = 0
                    panels[i].totalChars = 0
                    panels[i].typingAccumulator = 0
                    panels[i].fadeAlpha = 0
                    panels[i].dirty = true
                } else if t < rotationFadeDuration {
                    panels[i].fadeAlpha = t / rotationFadeDuration
                    panels[i].dirty = true
                } else if t > interval - rotationFadeDuration {
                    panels[i].fadeAlpha = (interval - t) / rotationFadeDuration
                    panels[i].dirty = true
                } else {
                    panels[i].fadeAlpha = 1.0
                }
            }

            if !panels[i].isFetching {
                let interval = panels[i].lastFetchOK
                    ? panels[i].refreshInterval
                    : min(panels[i].refreshInterval, failedRetryInterval)
                let elapsed = now.timeIntervalSince(panels[i].lastFetchTime)
                if panels[i].lastFetchTime == .distantPast || elapsed > interval {
                    fetchData(for: i)
                }
            }

            // Fetching panels mark dirty on the shared spinner tick boundary only —
            // otherwise we'd redraw at `textRedrawHz` while the visible glyph only
            // changes at spinnerHz. The shared tick fires below, outside the loop.

            // Typewriter progress — with slight timing jitter so it feels human.
            if panels[i].revealedChars < panels[i].totalChars {
                let jitter = 0.85 + 0.3 * Double.random(in: 0...1)
                panels[i].typingAccumulator += dt * panels[i].typingSpeed * jitter
                let newChars = Int(panels[i].typingAccumulator)
                if newChars > 0 {
                    panels[i].revealedChars = min(panels[i].revealedChars + newChars, panels[i].totalChars)
                    panels[i].typingAccumulator -= Double(newChars)
                    panels[i].dirty = true
                }
            } else if panels[i].totalChars > 0 {
                // Idle: mark dirty periodically so the pulsing cursor animates.
                let pulseInterval = 1.0 / idlePulseHz
                if nowMono - panels[i].lastIdlePulseTick >= pulseInterval {
                    panels[i].lastIdlePulseTick = nowMono
                    panels[i].dirty = true
                }
            }
        }

        // Advance the shared spinner tick. When it fires, mark every actively-
        // fetching panel dirty exactly once. 10Hz is the visible phase rate of
        // the 8-frame braille wheel.
        if nowMono - lastSpinnerTick >= 1.0 / spinnerHz {
            lastSpinnerTick = nowMono
            for i in panels.indices where panels[i].isFetching {
                panels[i].dirty = true
            }
        }

        // Render dirty panels at configured CT rate. Each panel's rect is cleared
        // and redrawn in isolation; unchanged panels' pixels persist from prior
        // frames, so idle slots cost zero CPU.
        if nowMono - lastCTRedraw >= minCTInterval {
            renderToTextureIfDirty()
            lastCTRedraw = nowMono
        }
    }

    private func fetchData(for index: Int) {
        panels[index].isFetching = true
        panels[index].dirty = true  // start showing spinner
        let stream = panels[index].currentStream
        let expectedStreamIndex = panels[index].activeStream

        // Preview mode: skip the network entirely and inject the stream's
        // hand-written preview snapshot. We don't show the spinner because
        // there's nothing to wait on — the "fetch" is synchronous.
        if isPreview {
            panels[index].isFetching = false
            apply(response: stream.previewResponse, to: index)
            // Park `lastFetchTime` in the future so no refresh ever re-fires.
            panels[index].lastFetchTime = .distantFuture
            return
        }

        stream.fetch { [weak self] response in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard index < self.panels.count else { return }
                guard self.panels[index].activeStream == expectedStreamIndex else {
                    self.panels[index].isFetching = false
                    return
                }
                self.panels[index].isFetching = false
                self.apply(response: response, to: index)
                self.panels[index].lastFetchTime = Date()
            }
        }
    }

    private func apply(response: StreamResponse, to index: Int) {
        panels[index].lines = response.lines
        panels[index].totalChars = response.lines.reduce(0) { $0 + $1.text.count }
        panels[index].revealedChars = 0
        panels[index].typingAccumulator = 0
        panels[index].lastFetchOK = response.ok
        panels[index].dirty = true
    }

    /// Redraw only the panels whose `dirty` flag is set. Each panel's rect is
    /// cleared, redrawn, and uploaded to the texture as a partial region —
    /// unchanged panels' pixels persist from prior frames at zero CPU/upload cost.
    private func renderToTextureIfDirty() {
        guard let data = bitmapData,
              let ctx = cgContext,
              let nsc = nsContext,
              !textures.isEmpty else { return }

        // Count dirty panels without allocating an array.
        var dirtyCount = 0
        for i in panels.indices where panels[i].dirty { dirtyCount += 1 }
        guard dirtyCount > 0 else { return }

        let t0 = CACurrentMediaTime()

        let previousNSCtx = NSGraphicsContext.current
        NSGraphicsContext.current = nsc

        let tex = textures[writeIndex]
        // Rasterize dirty panels and upload each region individually.
        // The texture is shared-storage, so `replace(region:)` is a memcpy.
        // Uploading only the dirty regions cuts bandwidth from `pixelWidth *
        // pixelHeight * 4` per frame to roughly one panel's worth — 20× less
        // when a single panel is pulsing.
        for i in panels.indices where panels[i].dirty {
            let ctxRect = panelRect(panels[i], extraRows: 1)
            ctx.clear(ctxRect)
            drawPanel(panels[i], in: ctx)
            panels[i].dirty = false

            // CG context Y is flipped relative to bitmap memory layout (see the
            // fullscreen vertex shader — it mirrors Y before sampling). Convert
            // the context rect to bitmap pixel coords for the upload.
            let pxX = Int(ctxRect.minX * scale)
            let pxW = Int(ctxRect.width * scale)
            let pxH = Int(ctxRect.height * scale)
            let pxYTop = pixelHeight - Int(ctxRect.maxY * scale)
            let clampedY = max(0, pxYTop)
            let clampedH = min(pxH, pixelHeight - clampedY)
            guard clampedH > 0, pxW > 0 else { continue }

            let region = MTLRegionMake2D(pxX, clampedY, pxW, clampedH)
            let bytesOffset = clampedY * bytesPerRow + pxX * 4
            tex.replace(region: region, mipmapLevel: 0,
                        withBytes: data.advanced(by: bytesOffset),
                        bytesPerRow: bytesPerRow)
        }

        NSGraphicsContext.current = previousNSCtx

        currentTextureIndex = writeIndex
        writeIndex = (writeIndex + 1) % textures.count

        let durationMs = (CACurrentMediaTime() - t0) * 1000
        PerfMonitor.shared.recordCT(durationMs: durationMs, dirtyCount: dirtyCount)
    }

    /// The panel's rect in CGContext user space (not bitmap pixels).
    private func panelRect(_ panel: Panel, extraRows: Int = 0) -> CGRect {
        CGRect(
            x: CGFloat(panel.origin.col) * cellSize.width,
            y: CGFloat(panel.origin.row) * cellSize.height,
            width: CGFloat(panel.size.cols) * cellSize.width,
            height: CGFloat(panel.size.rows + extraRows) * cellSize.height)
    }

    // 8-frame braille spinner, rendered during `isFetching`.
    private static let spinnerChars: [String] = [
        "\u{2807}", "\u{280B}", "\u{2819}", "\u{2838}",
        "\u{28B0}", "\u{28E0}", "\u{28C4}", "\u{2846}"
    ]

    /// Build one `[NSAttributedString.Key: Any]` dict per distinct color for this
    /// draw. All lines within a panel share the same fade alpha, so we can reuse
    /// faded NSColor instances across lines instead of allocating per-line.
    private func attrs(for color: NSColor, fade: CGFloat, cache: inout [NSColor: [NSAttributedString.Key: Any]]) -> [NSAttributedString.Key: Any] {
        if let hit = cache[color] { return hit }
        let faded = fade < 1.0 ? color.withAlphaComponent(fade) : color
        let dict: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: faded]
        cache[color] = dict
        return dict
    }

    private func drawPanel(_ panel: Panel, in ctx: CGContext) {
        let x = CGFloat(panel.origin.col) * cellSize.width
        var y = CGFloat(panel.origin.row) * cellSize.height
        let maxY = CGFloat(panel.origin.row + panel.size.rows) * cellSize.height
        let maxCols = panel.size.cols
        let fade = CGFloat(panel.fadeAlpha)

        ctx.saveGState()
        ctx.clip(to: CGRect(
            x: x,
            y: CGFloat(panel.origin.row) * cellSize.height,
            width: CGFloat(panel.size.cols) * cellSize.width,
            height: CGFloat(panel.size.rows) * cellSize.height))

        // Per-color attribute cache for this panel's draw pass — reused across
        // every line. Typical panel has 3-5 distinct colors, so we allocate
        // ~4 dicts instead of ~14.
        var attrCache: [NSColor: [NSAttributedString.Key: Any]] = [:]

        let headerBase: NSColor = panel.lastFetchOK ? Vulpes.hotPink : Vulpes.orange
        let spinner: String
        if panel.isFetching {
            let phase = Int(CACurrentMediaTime() * 10) % TextEngine.spinnerChars.count
            spinner = " " + TextEngine.spinnerChars[phase]
        } else {
            spinner = ""
        }
        let headerText = "[\(panel.name)]\(spinner)"
        NSAttributedString(string: headerText,
                           attributes: attrs(for: headerBase, fade: fade, cache: &attrCache))
            .draw(at: CGPoint(x: x, y: y))

        let headerCount = headerText.count + 1
        let sepStart = x + CGFloat(headerCount) * cellSize.width
        let sepLen = max(0, maxCols - headerCount)
        if sepLen > 0 {
            NSAttributedString(
                string: String(repeating: "\u{2500}", count: sepLen),
                attributes: attrs(for: Vulpes.mutedMagenta, fade: fade, cache: &attrCache))
                .draw(at: CGPoint(x: sepStart, y: y))
        }
        y += cellSize.height

        var charsShown = 0
        for line in panel.lines {
            guard y < maxY else { break }
            guard charsShown < panel.revealedChars else { break }

            // Account against the *visible* character count, not the untruncated
            // line length. Otherwise the typewriter "reveals" invisible chars of
            // long lines and the cursor sits idle for no apparent reason.
            let visibleLineCount = min(line.text.count, maxCols)
            let remaining = panel.revealedChars - charsShown
            let visibleCount = min(remaining, visibleLineCount)
            let truncated = String(line.text.prefix(maxCols))
            let visibleText = String(truncated.prefix(visibleCount))

            if !visibleText.isEmpty {
                NSAttributedString(string: visibleText,
                                   attributes: attrs(for: line.color, fade: fade, cache: &attrCache))
                    .draw(at: CGPoint(x: x, y: y))
            }

            if visibleCount < visibleLineCount && visibleCount > 0 {
                let cx = x + CGFloat(visibleCount) * cellSize.width
                NSAttributedString(string: "\u{25AE}",
                                   attributes: attrs(for: Vulpes.hotPink, fade: fade, cache: &attrCache))
                    .draw(at: CGPoint(x: cx, y: y))
            }

            // Advance the reveal counter by the full (untruncated) line count so
            // the typewriter keeps pace with lines the user can't fully see.
            charsShown += line.text.count
            y += cellSize.height
        }

        if panel.revealedChars >= panel.totalChars && panel.totalChars > 0 {
            let pulse = (sin(CACurrentMediaTime() * 4.0) + 1.0) / 2.0
            let alpha = CGFloat(pulse * 0.8 + 0.2) * fade
            NSAttributedString(string: "\u{25AE}", attributes: [
                .font: font,
                .foregroundColor: Vulpes.hotPink.withAlphaComponent(alpha)
            ]).draw(at: CGPoint(x: x, y: y))
        }

        ctx.restoreGState()
    }

    deinit {
        bitmapData?.deallocate()
    }
}
