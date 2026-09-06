// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-video-forge",
    // AVFoundation, CoreImage and ImageIO only — headless, no UI framework.
    // macOS 26 matches swift-image-forge, which this leans on for the still
    // side: a GIF is frames, and frames are that library's job. That floor
    // comes from the grading engine underneath it.
    platforms: [
        .macOS(.v26), .iOS(.v26)
    ],
    products: [
        .library(name: "VideoForge", targets: ["VideoForge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/arraypress/swift-image-forge.git", from: "0.2.0"),
    ],
    targets: [
        .target(
            name: "VideoForge",
            dependencies: [.product(name: "ImageForge", package: "swift-image-forge")]
        ),
        .testTarget(name: "VideoForgeTests", dependencies: ["VideoForge"]),
    ]
)
