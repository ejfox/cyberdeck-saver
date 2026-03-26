import Metal
import QuartzCore

struct Uniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var frame: UInt32
}

enum PerformanceMode {
    case full   // Apple Silicon: 60fps, full shader chain
    case lite   // Intel: 30fps, vignette + scanline only (cheap math, no multisampling)
}

class Renderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let mode: PerformanceMode

    // Shader pipelines
    private var bloomPipeline: MTLRenderPipelineState?
    private var tftPipeline: MTLRenderPipelineState?
    private let vignettePipeline: MTLRenderPipelineState
    private let scanlinePipeline: MTLRenderPipelineState
    private var glitchPipeline: MTLRenderPipelineState?

    // Intermediate textures for ping-pong rendering
    private var tempTextureA: MTLTexture?
    private var tempTextureB: MTLTexture?

    private let startTime: CFAbsoluteTime
    private var frameCount: UInt32 = 0

    var glitchEnabled = false

    init?(device: MTLDevice, bundle: Bundle) {
        self.device = device
        guard let cq = device.makeCommandQueue() else { return nil }
        self.commandQueue = cq
        self.startTime = CFAbsoluteTimeGetCurrent()

        // Detect GPU — Apple Silicon GPUs have names like "Apple M1 Pro"
        let gpuName = device.name
        let isAppleSilicon = gpuName.lowercased().contains("apple")
        self.mode = isAppleSilicon ? .full : .lite
        NSLog("CyberdeckSaver: GPU=\(gpuName) mode=\(isAppleSilicon ? "full" : "lite")")

        // Load Metal shader library from the screensaver bundle
        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            NSLog("CyberdeckSaver: Failed to load Metal library from bundle")
            return nil
        }

        guard let vertexFunc = library.makeFunction(name: "fullscreen_vertex") else {
            NSLog("CyberdeckSaver: Missing fullscreen_vertex function")
            return nil
        }

        func makePipeline(_ fragmentName: String) -> MTLRenderPipelineState? {
            guard let fragFunc = library.makeFunction(name: fragmentName) else {
                NSLog("CyberdeckSaver: Missing fragment function: \(fragmentName)")
                return nil
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFunc
            desc.fragmentFunction = fragFunc
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: desc)
        }

        // Always build vignette + scanline (cheap, pure math)
        guard let vignette = makePipeline("vignette_fragment"),
              let scanline = makePipeline("scanline_fragment") else {
            NSLog("CyberdeckSaver: Failed to create core pipelines")
            return nil
        }
        vignettePipeline = vignette
        scanlinePipeline = scanline

        // Expensive shaders only on Apple Silicon
        if mode == .full {
            bloomPipeline = makePipeline("bloom_fragment")
            tftPipeline = makePipeline("tft_fragment")
            glitchPipeline = makePipeline("glitch_fragment")
            NSLog("CyberdeckSaver: Full pipeline — bloom + tft + vignette + scanline")
        } else {
            NSLog("CyberdeckSaver: Lite pipeline — vignette + scanline only")
        }
    }

    /// Recommended animation interval based on GPU capability
    var recommendedInterval: TimeInterval {
        mode == .full ? 1.0 / 30.0 : 1.0 / 20.0
    }

    func resize(to size: CGSize) {
        let w = Int(size.width)
        let h = Int(size.height)
        guard w > 0 && h > 0 else { return }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private

        tempTextureA = device.makeTexture(descriptor: desc)
        tempTextureB = device.makeTexture(descriptor: desc)
    }

    func render(textEngine: TextEngine, to drawable: CAMetalDrawable) {
        guard let textTexture = textEngine.texture,
              let tempA = tempTextureA,
              let tempB = tempTextureB else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        var uniforms = Uniforms(
            resolution: SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height)),
            time: Float(CFAbsoluteTimeGetCurrent() - startTime),
            frame: frameCount)
        frameCount &+= 1

        // Build shader chain based on performance mode
        var chain: [(MTLRenderPipelineState, MTLTexture, MTLTexture)]

        if mode == .full {
            // Full chain: text → bloom → tft → vignette → scanline → drawable
            chain = []
            if let bloom = bloomPipeline {
                chain.append((bloom, textTexture, tempA))
                if let tft = tftPipeline {
                    chain.append((tft, tempA, tempB))
                    chain.append((vignettePipeline, tempB, tempA))
                } else {
                    chain.append((vignettePipeline, tempA, tempB))
                    // swap so next reads from correct texture
                    let _ = tempA // tempB has vignette output
                }
            } else {
                chain.append((vignettePipeline, textTexture, tempA))
            }

            if glitchEnabled, let glitch = glitchPipeline {
                let lastOutput = chain.last!.2
                let nextTemp = (lastOutput === tempA) ? tempB : tempA
                chain.append((scanlinePipeline, lastOutput, nextTemp))
                chain.append((glitch, nextTemp, drawable.texture))
            } else {
                let lastOutput = chain.last!.2
                chain.append((scanlinePipeline, lastOutput, drawable.texture))
            }
        } else {
            // Lite chain: text → vignette → scanline → drawable
            chain = [
                (vignettePipeline, textTexture, tempA),
                (scanlinePipeline, tempA, drawable.texture),
            ]
        }

        for (pipeline, input, output) in chain {
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

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
