import CoreGraphics
import KoiPondCore
import Metal
import QuartzCore

/// Steps one screen's pond and draws it: water and animals into a low-resolution scene texture,
/// then upscaled with weather grading into the view.
public final class PondRenderer {
    let ctx: MetalContext
    public let pond: Pond
    public private(set) var settings: PondSettings
    public var backingScale: Float
    /// False while paused: frames still draw (for a still wallpaper) but time stands still.
    public var advancing = true
    /// Where the music comes from, read once a frame; nil keeps the pond silent.
    public var music: (() -> PondMusic)?

    private var look: WeatherLook
    private var lookTarget: WeatherLook
    private var weatherRefresh: Float = 0
    private var lightning: Float = 0
    private var lightningCountdown: Float = 6
    private var pendingFlashes: [Float] = []
    private var scene: MTLTexture?

    public init(ctx: MetalContext, size: SIMD2<Float>, backingScale: Float, settings: PondSettings, seed: UInt64) {
        self.ctx = ctx
        pond = Pond(size: size, seed: seed)
        self.settings = settings
        self.backingScale = backingScale
        look = settings.weather.look(at: Date())
        lookTarget = look
        apply(settings)
    }

    public func apply(_ s: PondSettings) {
        settings = s
        pond.configure(PondConfig(s))
        pond.behavior = s.behavior
        pond.currentsEnabled = s.currentsEnabled
        pond.currentSpeed = Float(s.currentSpeed)
        lookTarget = s.weather.look(at: Date())
    }

    /// One frame's worth of time: the music comes in, then the pond and weather move on unless paused.
    public func tick(dt: Float) {
        if let music { pond.music = music() }
        advance(dt: advancing ? dt : 0)
    }

    // MARK: Simulation

    public func advance(dt: Float) {
        weatherRefresh -= dt
        if weatherRefresh <= 0 {
            lookTarget = settings.weather.look(at: Date())
            weatherRefresh = 20
        }
        look = dt > 0 ? WeatherLook.mix(look, lookTarget, min(1, dt * 1.2)) : lookTarget
        pond.rain = look.rain
        pond.currentStrength = Float(settings.currentStrength) * (1 + look.storm * 0.8)
        pond.step(dt: dt * Float(settings.motionSpeed))
        updateLightning(dt)
    }

    private func updateLightning(_ dt: Float) {
        lightning = max(0, lightning - dt * 3.5)
        guard look.storm > 0.5 else {
            pendingFlashes.removeAll()
            return
        }
        lightningCountdown -= dt
        if lightningCountdown <= 0 {
            lightningCountdown = Float.random(in: 7...16)
            pendingFlashes = [0, Float.random(in: 0.12...0.25)]
        }
        pendingFlashes = pendingFlashes.compactMap { remaining in
            let next = remaining - dt
            if next <= 0 {
                lightning = 1
                return nil
            }
            return next
        }
    }

    // MARK: Rendering

    func encode(_ commands: MTLCommandBuffer, finalPass: MTLRenderPassDescriptor) {
        let texelsPerPoint = settings.quality.texelsPerPoint(backingScale: backingScale)
        let scene = sceneTexture(width: max(1, Int((pond.size.x * texelsPerPoint).rounded())),
                                 height: max(1, Int((pond.size.y * texelsPerPoint).rounded())))
        var uniforms = makeUniforms(pointsPerTexel: 1 / texelsPerPoint)
        let uniformLength = MemoryLayout<GPUUniforms>.stride
        let instances = InstanceBuilder.build(pond: pond)

        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = scene
        scenePass.colorAttachments[0].loadAction = .dontCare
        scenePass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: scenePass) {
            encoder.setRenderPipelineState(ctx.waterPipeline)
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            let buffer = instances.withUnsafeBytes { bytes in
                bytes.baseAddress.flatMap { ctx.device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
            }
            if let buffer {
                encoder.setRenderPipelineState(ctx.instancePipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: uniformLength, index: 1)
                encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
                encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
            }
            encoder.endEncoding()
        }

        if let encoder = commands.makeRenderCommandEncoder(descriptor: finalPass) {
            encoder.setRenderPipelineState(ctx.compositePipeline)
            encoder.setFragmentTexture(scene, index: 0)
            encoder.setFragmentSamplerState(settings.quality == .pixel ? ctx.nearestSampler : ctx.linearSampler, index: 0)
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }

    private func makeUniforms(pointsPerTexel: Float) -> GPUUniforms {
        let s = settings
        let clarity = max(0, min(1, Float(s.clarity) + look.clarityBoost))
        let currents = s.currentsEnabled ? Float(s.currentStrength) * (1 + look.storm * 0.8) : 0
        return GPUUniforms(
            world: [pond.size.x, pond.size.y, pond.time, s.quality == .pixel ? 1 : 0],
            water: SIMD4(s.waterColor.simd, clarity),
            tint: SIMD4(look.tint, look.ambient),
            glow: SIMD4(look.glowColor, look.glow * Float(s.coreGlow) * 2),
            fx: [look.caustics, currents, pond.flowTime, look.rain],
            fx2: [lightning, look.saturation, pointsPerTexel, 0])
    }

    private func sceneTexture(width: Int, height: Int) -> MTLTexture {
        if let scene, scene.width == width, scene.height == height { return scene }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = ctx.device.makeTexture(descriptor: descriptor)!
        scene = texture
        return texture
    }

    /// Draws the current frame into `target` and waits for the GPU to finish.
    public func render(into target: MTLTexture) {
        guard let commands = encodeFrame(into: target) else { return }
        commands.commit()
        commands.waitUntilCompleted()
    }

    /// Renders one frame into `target` without waiting; `done` runs on the main thread once the GPU has finished.
    public func render(into target: MTLTexture, done: @escaping () -> Void) {
        guard let commands = encodeFrame(into: target) else { return DispatchQueue.main.async(execute: done) }
        commands.addCompletedHandler { _ in DispatchQueue.main.async(execute: done) }
        commands.commit()
    }

    private func encodeFrame(into target: MTLTexture) -> MTLCommandBuffer? {
        guard let commands = ctx.queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        encode(commands, finalPass: pass)
        return commands
    }

    /// Renders one frame offscreen and reads it back.
    public func renderImage(width: Int, height: Int) -> CGImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = ctx.device.makeTexture(descriptor: descriptor) else { return nil }
        render(into: target)

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?
                .makeImage()
        }
    }
}
