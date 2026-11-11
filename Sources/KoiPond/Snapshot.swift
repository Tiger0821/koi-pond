import Foundation
import KoiPondRender
import ImageIO
import KoiPondCore
import UniformTypeIdentifiers

/// `KoiPond --snapshot out.png [--weather sunset] [--behavior curious]
///  [--size 1512x982] [--scale 2] [--seconds 8] [--feed 700,500] [--touch 700,500] [--touch-age 0.5] [--beat 120]
///  [--lineup "variety[:design]@x,y,heading,length[,depth,phase,seed];…"]`
/// renders one frame offscreen without opening any windows.
enum SnapshotCommand {
    static func runIfRequested() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return false }
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func point(_ flag: String) -> SIMD2<Float>? {
            let parts = value(flag)?.split(separator: ",").compactMap { Float($0) } ?? []
            return parts.count == 2 ? SIMD2(parts[0], parts[1]) : nil
        }

        var settings = PondSettings()
        if let raw = value("--weather"), let weather = WeatherPreset(rawValue: raw) { settings.weather = weather }
        if let raw = value("--behavior"), let behavior = FishBehavior(rawValue: raw) { settings.behavior = behavior }
        let size = value("--size")?.split(separator: "x").compactMap { Float($0) } ?? []
        let worldSize = size.count == 2 ? SIMD2(size[0], size[1]) : SIMD2<Float>(1512, 982)
        let scale = value("--scale").flatMap(Float.init) ?? 2
        let seconds = value("--seconds").flatMap(Float.init) ?? 8

        guard let ctx = MetalContext.make() else {
            FileHandle.standardError.write(Data("Metal is unavailable\n".utf8))
            exit(1)
        }
        if let videoPath = value("--video") {
            let start = Date()
            _ = try? PondVideoWriter.write(to: URL(fileURLWithPath: videoPath), ctx: ctx, settings: settings, worldSize: worldSize,
                                       pixelWidth: Int(worldSize.x * scale), pixelHeight: Int(worldSize.y * scale),
                                       seconds: Int(seconds))
            print("Wrote \(videoPath) in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        }
        // `--lineup "ogon@700,500,0.3,100;kigoi@…"` draws hand-placed koi on bare water instead of the pond's animals.
        let renderer = PondRenderer(ctx: ctx, size: worldSize, settings: settings, seed: 42)
        renderer.lineup = value("--lineup").map(LineupKoi.parse)
        if let feed = point("--feed") { renderer.pond.dropFood(at: feed, count: 10) }
        let bpm = value("--beat").flatMap(Float.init)
        for frame in 0..<Int(seconds * 60) {
            // `--beat 120` plays a steady beat at full loudness, for seeing the fish dance.
            if let bpm { renderer.pond.music = PondMusic(level: 1, beats: Int(Float(frame) / 60 * bpm / 60)) }
            renderer.advance(dt: 1 / 60)
        }
        if let touch = point("--touch") {
            renderer.pond.touch(at: touch)
            let age = value("--touch-age").flatMap(Float.init) ?? 0.5
            for _ in 0..<Int(age * 30) { renderer.advance(dt: 1 / 30) }
        }

        let url = URL(fileURLWithPath: args[index + 1])
        guard let image = renderer.renderImage(width: Int(worldSize.x * scale), height: Int(worldSize.y * scale)),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            FileHandle.standardError.write(Data("Could not render the snapshot\n".utf8))
            exit(1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { exit(1) }
        print("Wrote \(url.path)")
        return true
    }
}
