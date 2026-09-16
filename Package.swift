// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zeptun",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "Zeptun", targets: ["Zeptun"]),
    ],
    targets: [
        .binaryTarget(name: "Zeptun", path: "zig-out/Zeptun.xcframework"),
    ]
)
