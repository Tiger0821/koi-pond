// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "KoiPond",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KoiPond", targets: ["KoiPond"]),
        // Wrapped into KoiPond.saver by scripts/build-app.sh.
        .library(name: "KoiPondSaver", type: .dynamic, targets: ["KoiPondSaver"]),
    ],
    targets: [
        .target(name: "KoiPondCore"),
        .target(name: "KoiPondRender", dependencies: ["KoiPondCore"]),
        .executableTarget(name: "KoiPond", dependencies: ["KoiPondCore", "KoiPondRender"]),
        .target(name: "KoiPondSaver", dependencies: ["KoiPondCore", "KoiPondRender"]),
        .testTarget(name: "KoiPondCoreTests", dependencies: ["KoiPondCore"]),
    ]
)
