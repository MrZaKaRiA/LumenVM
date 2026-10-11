// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lumen",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Lumen", targets: ["Lumen"])],
    targets: [
        .target(name: "LumenCore"),
        .executableTarget(name: "Lumen", dependencies: ["LumenCore"]),
        .testTarget(name: "LumenCoreTests", dependencies: ["LumenCore"])
    ]
)
