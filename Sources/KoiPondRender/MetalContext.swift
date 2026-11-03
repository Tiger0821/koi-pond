import Metal

/// Device, queue and pipelines shared by every screen's renderer.
public final class MetalContext {
    enum SetupError: Error {
        case noDevice
    }

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let waterPipeline: MTLRenderPipelineState
    let instancePipeline: MTLRenderPipelineState
    let compositePipeline: MTLRenderPipelineState
    let nearestSampler: MTLSamplerState
    let linearSampler: MTLSamplerState

    public static func make() -> MetalContext? {
        do {
            return try MetalContext()
        } catch {
            Log.info("Metal setup failed: \(error)")
            return nil
        }
    }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SetupError.noDevice
        }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: ShaderSource.metal, options: nil)

        func pipeline(_ vertex: String, _ fragment: String, blended: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            if blended {
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .sourceAlpha
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        waterPipeline = try pipeline("fullscreen_vertex", "water_fragment", blended: false)
        instancePipeline = try pipeline("instance_vertex", "instance_fragment", blended: true)
        compositePipeline = try pipeline("fullscreen_vertex", "composite_fragment", blended: false)

        func sampler(_ filter: MTLSamplerMinMagFilter) -> MTLSamplerState {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = filter
            descriptor.magFilter = filter
            descriptor.sAddressMode = .clampToEdge
            descriptor.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: descriptor)!
        }
        nearestSampler = sampler(.nearest)
        linearSampler = sampler(.linear)
    }
}
