import Metal
import QuartzCore

struct Uniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var frame: UInt32
}

enum PerformanceMode {
    case full   // Apple Silicon: 60fps, full shader chain
    case lite   // Intel: 30fps, vignette + scanline only
}

class Renderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let mode: PerformanceMode

    // Pipelines — vignette and scanline always exist, bloom/tft/glitch are optional.
    private let vignettePipeline: MTLRenderPipelineState
    private let scanlinePipeline: MTLRenderPipelineState
    private let bloomPipeline: MTLRenderPipelineState?
    private let tftPipeline: MTLRenderPipelineState?
    private let glitchPipeline: MTLRenderPipelineState?

    // Ping-pong textures for intermediate passes.
    private var tempA: MTLTexture?
    private var tempB: MTLTexture?

    private let startTime: CFAbsoluteTime
    private var frameCount: UInt32 = 0

    var glitchEnabled: Bool

    init?(device: MTLDevice, bundle: Bundle, config: CyberdeckConfig) {
        self.device = device
        guard let cq = device.makeCommandQueue() else { return nil }
        self.commandQueue = cq
        self.startTime = CFAbsoluteTimeGetCurrent()
        self.glitchEnabled = config.render.glitch

        // Apple Silicon GPUs report names like "Apple M1 Pro".
        // Config can force a mode — useful for testing or when auto-detection is wrong.
        let isAppleSilicon = device.name.lowercased().contains("apple")
        let detected: PerformanceMode = isAppleSilicon ? .full : .lite
        switch config.render.forceMode {
        case "full": self.mode = .full
        case "lite": self.mode = .lite
        default:     self.mode = detected
        }
        Diag.log("GPU=\(device.name) mode=\(self.mode == .full ? "full" : "lite")")

        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            Diag.log("Failed to load Metal library from bundle")
            return nil
        }
        guard let vertexFunc = library.makeFunction(name: "fullscreen_vertex") else {
            Diag.log("Missing fullscreen_vertex function")
            return nil
        }

        func pipeline(_ fragmentName: String) -> MTLRenderPipelineState? {
            guard let fragFunc = library.makeFunction(name: fragmentName) else {
                Diag.log("Missing fragment function: \(fragmentName)")
                return nil
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFunc
            desc.fragmentFunction = fragFunc
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: desc)
        }

        guard let vignette = pipeline("vignette_fragment"),
              let scanline = pipeline("scanline_fragment") else {
            Diag.log("Failed to create core pipelines")
            return nil
        }
        self.vignettePipeline = vignette
        self.scanlinePipeline = scanline

        if mode == .full {
            self.bloomPipeline = pipeline("bloom_fragment")
            self.tftPipeline = pipeline("tft_fragment")
            self.glitchPipeline = pipeline("glitch_fragment")
            Diag.log("Full pipeline — bloom + tft + vignette + scanline")
        } else {
            self.bloomPipeline = nil
            self.tftPipeline = nil
            self.glitchPipeline = nil
            Diag.log("Lite pipeline — vignette + scanline only")
        }
    }

    /// 60fps on Apple Silicon, 30fps on Intel. Scanline + glitch shaders are
    /// tuned for 60fps sampling — dropping below aliases the flicker.
    var recommendedInterval: TimeInterval {
        mode == .full ? 1.0 / 60.0 : 1.0 / 30.0
    }

    func resize(to size: CGSize) {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        tempA = device.makeTexture(descriptor: desc)
        tempB = device.makeTexture(descriptor: desc)
    }

    func render(textEngine: TextEngine, to drawable: CAMetalDrawable) {
        guard let textTexture = textEngine.currentTexture,
              let tempA = tempA,
              let tempB = tempB,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        var uniforms = Uniforms(
            resolution: SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height)),
            time: Float(CFAbsoluteTimeGetCurrent() - startTime),
            frame: frameCount)
        frameCount &+= 1

        // Build the chain as concrete (pipeline, input, output) triples.
        // Ping-pong between tempA and tempB; the final pass writes to drawable.
        var stages: [(MTLRenderPipelineState, MTLTexture, MTLTexture)] = []

        if mode == .full {
            // Full: text -> bloom -> tft -> vignette -> [glitch?] -> scanline -> drawable
            var current = textTexture
            var nextIsA = true
            func appendStage(_ p: MTLRenderPipelineState) {
                let out = nextIsA ? tempA : tempB
                stages.append((p, current, out))
                current = out
                nextIsA.toggle()
            }
            if let bloom = bloomPipeline { appendStage(bloom) }
            if let tft = tftPipeline     { appendStage(tft) }
            appendStage(vignettePipeline)
            if glitchEnabled, let glitch = glitchPipeline { appendStage(glitch) }
            stages.append((scanlinePipeline, current, drawable.texture))
        } else {
            // Lite: text -> vignette -> scanline -> drawable
            stages.append((vignettePipeline, textTexture, tempA))
            stages.append((scanlinePipeline, tempA, drawable.texture))
        }

        for (pipeline, input, output) in stages {
            let passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = output
            passDesc.colorAttachments[0].loadAction = .dontCare
            passDesc.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { continue }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(input, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // Record GPU frame time for perf monitoring. The double-buffered text
        // texture relies on typical 1-frame GPU latency — we're confident enough
        // that by the time we come back around to writeIndex N, the GPU is done
        // with it. If that ever tears visually, upgrade to a semaphore-gated
        // triple-buffer here.
        let gpuStart = CACurrentMediaTime()
        commandBuffer.addCompletedHandler { _ in
            let durationMs = (CACurrentMediaTime() - gpuStart) * 1000
            PerfMonitor.shared.recordGPU(durationMs: durationMs)
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
