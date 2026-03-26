import AppKit
import Metal
import CoreText

struct Panel {
    let name: String
    let stream: DataStream
    let typingSpeed: Double
    let refreshInterval: TimeInterval

    var origin: (col: Int, row: Int) = (0, 0)
    var size: (cols: Int, rows: Int) = (0, 0)

    var lines: [FormattedLine] = []
    var revealedChars: Int = 0
    var totalChars: Int = 0
    var typingAccumulator: Double = 0
    var lastFetchTime: Date = .distantPast
    var isFetching: Bool = false
    var startDelay: Double = 0  // seconds before this panel starts typing
    var age: Double = 0         // time since panel was created
}

class TextEngine {
    let device: MTLDevice
    var texture: MTLTexture?

    private var bitmapData: UnsafeMutableRawPointer?
    private var cgContext: CGContext?
    private var nsContext: NSGraphicsContext?
    private var panels: [Panel] = []
    private var font: NSFont
    private var cellSize: CGSize
    private var gridSize: (cols: Int, rows: Int) = (0, 0)
    private var pointSize: CGSize = .zero
    private var pixelWidth: Int = 0
    private var pixelHeight: Int = 0
    private var scale: CGFloat = 2.0
    private var bytesPerRow: Int = 0
    private var started = false
    private var isDirty = true

    init(device: MTLDevice, size: CGSize, scale: CGFloat) {
        self.device = device
        self.scale = scale

        let fontSize: CGFloat = 12.0
        self.font = NSFont(name: "MonaspiceKrNFM-Regular", size: fontSize)
            ?? NSFont(name: "Menlo-Regular", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        self.cellSize = NSString(string: "M").size(withAttributes: attrs)

        setupPanels()
        resize(to: size, scale: scale)
    }

    private func setupPanels() {
        // All real data. VPS OSINT feeds + personal APIs + system data.
        panels = [
            // Row 0: Command + VPS OSINT
            Panel(name: "CMD",        stream: CommandStream(),       typingSpeed: 9999, refreshInterval: 1),
            Panel(name: "SKYWATCH",   stream: SkywatchStream(),     typingSpeed: 1500, refreshInterval: 60),
            Panel(name: "ANOMALY",    stream: AnomalywatchStream(), typingSpeed: 1200, refreshInterval: 45),
            Panel(name: "BRIEFING",   stream: BriefingsStream(),    typingSpeed: 1000, refreshInterval: 300),

            // Row 1: OSINT + personal
            Panel(name: "OVERWATCH",  stream: OverwatchStream(),    typingSpeed: 1200, refreshInterval: 90),
            Panel(name: "SIGINT",     stream: GitHubStream(),       typingSpeed: 1500, refreshInterval: 90),
            Panel(name: "ACINT",      stream: MusicStream(),        typingSpeed: 1200, refreshInterval: 30),
            Panel(name: "COMINT",     stream: MastodonStream(),     typingSpeed: 1000, refreshInterval: 60),

            // Row 2: Biometrics + productivity
            Panel(name: "BIOMETRIC",  stream: HealthStream(),       typingSpeed: 1500, refreshInterval: 120),
            Panel(name: "SYSINFO",    stream: SystemStream(),       typingSpeed: 2000, refreshInterval: 10),
            Panel(name: "PRODINT",    stream: RescueTimeStream(),   typingSpeed: 1200, refreshInterval: 120),
            Panel(name: "METRICS",    stream: StatsStream(),        typingSpeed: 1500, refreshInterval: 120),

            // Row 3: Skills + forecasting
            Panel(name: "GAMEINT",    stream: ChessStream(),        typingSpeed: 1200, refreshInterval: 300),
            Panel(name: "KEYINT",     stream: TypingStream(),       typingSpeed: 1200, refreshInterval: 120),
            Panel(name: "CODEINT",    stream: LeetCodeStream(),      typingSpeed: 1200, refreshInterval: 120),
            Panel(name: "OSINT-W",    stream: WordsStream(),        typingSpeed: 1200, refreshInterval: 120),
        ]
    }

    func resize(to size: CGSize, scale: CGFloat) {
        self.pointSize = size
        self.scale = scale
        pixelWidth = max(1, Int(size.width * scale))
        pixelHeight = max(1, Int(size.height * scale))

        gridSize.cols = max(1, Int(size.width / cellSize.width))
        gridSize.rows = max(1, Int(size.height / cellSize.height))

        bytesPerRow = pixelWidth * 4
        let totalBytes = bytesPerRow * pixelHeight
        bitmapData?.deallocate()
        bitmapData = UnsafeMutableRawPointer.allocate(byteCount: totalBytes, alignment: 16)
        memset(bitmapData!, 0, totalBytes)

        // Create CGContext once, reuse every frame
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

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: pixelWidth, height: pixelHeight, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        texture = device.makeTexture(descriptor: desc)

        layoutPanels()
        isDirty = true
    }

    private func layoutPanels() {
        let cols = 4
        let rows = (panels.count + cols - 1) / cols
        let colWidth = gridSize.cols / cols
        let rowHeight = gridSize.rows / rows

        for i in panels.indices {
            let c = i % cols
            let r = i / cols
            panels[i].origin = (c * colWidth + 1, r * rowHeight + 1)
            panels[i].size = (colWidth - 2, rowHeight - 1)
        }
    }

    func start() {
        started = true
        // Stagger panel startups so they don't all fire at once
        for i in panels.indices {
            panels[i].startDelay = Double(i) * 0.4 + Double.random(in: 0...1.5)
            panels[i].age = 0
        }
    }

    func stop() {
        started = false
    }

    func update(dt: TimeInterval) {
        guard started else { return }

        for i in panels.indices {
            panels[i].age += dt

            // Don't do anything until startup delay has passed
            guard panels[i].age > panels[i].startDelay else { continue }

            // First fetch happens after startup delay
            if panels[i].lastFetchTime == .distantPast && !panels[i].isFetching {
                fetchData(for: i)
                continue
            }

            // Refresh data when interval elapses
            let elapsed = Date().timeIntervalSince(panels[i].lastFetchTime)
            if elapsed > panels[i].refreshInterval && !panels[i].isFetching {
                fetchData(for: i)
            }

            // Advance typewriter independently
            if panels[i].revealedChars < panels[i].totalChars {
                panels[i].typingAccumulator += dt * panels[i].typingSpeed
                let newChars = Int(panels[i].typingAccumulator)
                if newChars > 0 {
                    panels[i].revealedChars = min(panels[i].revealedChars + newChars, panels[i].totalChars)
                    panels[i].typingAccumulator -= Double(newChars)
                    isDirty = true
                }
            }
        }

        if isDirty {
            renderToTexture()
            isDirty = false
        }
    }

    private func fetchData(for index: Int) {
        panels[index].isFetching = true
        panels[index].stream.fetch { [weak self] lines in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.panels[index].lines = lines
                self.panels[index].totalChars = lines.reduce(0) { $0 + $1.text.count }
                self.panels[index].revealedChars = 0
                self.panels[index].typingAccumulator = 0
                self.panels[index].lastFetchTime = Date()
                self.panels[index].isFetching = false
                self.isDirty = true
            }
        }
    }

    private func renderToTexture() {
        guard let tex = texture, let data = bitmapData,
              let ctx = cgContext, let nsc = nsContext else { return }

        // Fast clear with memset (opaque black = all zero bytes + alpha)
        // BGRA: we need A=0xFF. memset to 0 gives transparent black,
        // so use a
        // vDSP or just accept transparent — the shaders don't care about alpha
        memset(data, 0, bytesPerRow * pixelHeight)

        let previousNSCtx = NSGraphicsContext.current
        NSGraphicsContext.current = nsc

        for panel in panels {
            drawPanel(panel, in: ctx)
        }

        NSGraphicsContext.current = previousNSCtx

        let region = MTLRegionMake2D(0, 0, pixelWidth, pixelHeight)
        tex.replace(region: region, mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
    }

    private func drawPanel(_ panel: Panel, in ctx: CGContext) {
        let x = CGFloat(panel.origin.col) * cellSize.width
        var y = CGFloat(panel.origin.row) * cellSize.height
        let maxY = CGFloat(panel.origin.row + panel.size.rows) * cellSize.height
        let maxCols = panel.size.cols

        // Clip to panel bounds
        ctx.saveGState()
        ctx.clip(to: CGRect(x: x, y: CGFloat(panel.origin.row) * cellSize.height,
                            width: CGFloat(panel.size.cols) * cellSize.width,
                            height: CGFloat(panel.size.rows) * cellSize.height))

        // Header
        let header = NSAttributedString(string: "[\(panel.name)]", attributes: [
            .font: font, .foregroundColor: Vulpes.hotPink
        ])
        header.draw(at: CGPoint(x: x, y: y))

        // Separator on same line, after header
        let sepStart = x + CGFloat(panel.name.count + 3) * cellSize.width
        let sepLen = max(0, maxCols - panel.name.count - 3)
        if sepLen > 0 {
            let sep = NSAttributedString(
                string: String(repeating: "\u{2500}", count: sepLen),
                attributes: [.font: font, .foregroundColor: Vulpes.mutedMagenta])
            sep.draw(at: CGPoint(x: sepStart, y: y))
        }
        y += cellSize.height

        // Content
        var charsShown = 0
        for line in panel.lines {
            guard y < maxY else { break }
            guard charsShown < panel.revealedChars else { break }

            let remaining = panel.revealedChars - charsShown
            let visibleCount = min(remaining, line.text.count)
            // Truncate to panel width
            let truncated = String(line.text.prefix(maxCols))
            let visibleText = String(truncated.prefix(visibleCount))

            if !visibleText.isEmpty {
                let str = NSAttributedString(string: visibleText, attributes: [
                    .font: font, .foregroundColor: line.color
                ])
                str.draw(at: CGPoint(x: x, y: y))
            }

            // Typing cursor
            if visibleCount < line.text.count && visibleCount > 0 {
                let cx = x + CGFloat(visibleCount) * cellSize.width
                let cur = NSAttributedString(string: "\u{25AE}", attributes: [
                    .font: font, .foregroundColor: Vulpes.hotPink
                ])
                cur.draw(at: CGPoint(x: cx, y: y))
            }

            charsShown += line.text.count
            y += cellSize.height
        }

        // Idle cursor
        if panel.revealedChars >= panel.totalChars && panel.totalChars > 0 {
            let pulse = (sin(CACurrentMediaTime() * 4.0) + 1.0) / 2.0
            let alpha = CGFloat(pulse * 0.8 + 0.2)
            let cur = NSAttributedString(string: "\u{25AE}", attributes: [
                .font: font, .foregroundColor: Vulpes.hotPink.withAlphaComponent(alpha)
            ])
            cur.draw(at: CGPoint(x: x, y: y))
        }

        ctx.restoreGState()
    }

    deinit {
        bitmapData?.deallocate()
    }
}
