import AVFoundation
import KoiPondRender
import CoreVideo
import KoiPondCore
import Metal
import VideoToolbox

/// Records the pond into an HEVC movie shaped like Apple's aerials: video only, no audio,
/// with the movie header at the front, and frames split into temporal layers. Frames are drawn
/// straight into the encoder's IOSurface-backed buffers, so nothing is copied back from the GPU.
enum PondVideoWriter {
    /// Changes whenever the movie's encoding changes, so installed recordings are redone.
    static let formatVersion = 2

    enum WriteError: LocalizedError {
        case setup(String)

        var errorDescription: String? {
            switch self {
            case .setup(let detail): "Couldn't record the pond video (\(detail))."
            }
        }
    }

    /// Writes `seconds` of continuous pond to `url` and returns the first frame for the lock screen still.
    @discardableResult
    static func write(to url: URL, ctx: MetalContext, settings: PondSettings, worldSize: SIMD2<Float>,
                      pixelWidth: Int, pixelHeight: Int, seconds: Int, fps: Int = 30,
                      progress: (Double) -> Void = { _ in }) throws -> CGImage? {
        let width = pixelWidth & ~1
        let height = pixelHeight & ~1
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(Double(width * height * fps) * 0.05),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                // Every other frame in a base layer, tagged with its temporal level the way Apple's aerials
                // are. macOS slows the lock screen movie to a stop on unlock by picking frames by level; with
                // no levels it fails ("noTemporalInfo") and that player never plays again until it restarts.
                kVTCompressionPropertyKey_BaseLayerFrameRate as String: Double(fps) / 2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(input) else { throw WriteError.setup("encoder rejected the format") }
        writer.add(input)
        guard writer.startWriting() else { throw WriteError.setup(writer.error?.localizedDescription ?? "writer failed") }
        writer.startSession(atSourceTime: .zero)

        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, ctx.device, nil, &textureCache)
        guard let textureCache else { throw WriteError.setup("no texture cache") }
        let textureAttributes = [kCVMetalTextureUsage as String: MTLTextureUsage([.renderTarget, .shaderRead]).rawValue]

        let renderer = PondRenderer(ctx: ctx, size: worldSize, settings: settings, seed: 0x6C6F636B)
        // Let the animals spread out before the first frame.
        for _ in 0..<90 { renderer.advance(dt: 1 / 30) }

        var firstFrame: CGImage?
        let frameCount = seconds * fps
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard let pool = adaptor.pixelBufferPool else { throw WriteError.setup("no pixel buffer pool") }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            var cvTexture: CVMetalTexture?
            if let pixelBuffer {
                CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, textureAttributes as CFDictionary,
                                                          .bgra8Unorm, width, height, 0, &cvTexture)
            }
            guard let pixelBuffer, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
                throw WriteError.setup("couldn't map a frame for Metal")
            }
            if frame > 0 { renderer.advance(dt: 1 / Float(fps)) }
            renderer.render(into: texture)
            if frame == 0 { firstFrame = renderer.renderImage(width: width, height: height) }
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) else {
                throw WriteError.setup(writer.error?.localizedDescription ?? "append failed")
            }
            if frame % fps == 0 { progress(Double(frame) / Double(frameCount)) }
        }

        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw WriteError.setup(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
        progress(1)
        return firstFrame
    }
}
