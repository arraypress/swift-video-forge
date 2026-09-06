// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "swift-video-forge",
    // AVFoundation, CoreImage and ImageIO only — headless, no UI framework.
    // macOS 15 matches swift-image-forge, which this leans on for the still
    // side: a GIF is frames, and frames are that library's job.
    platforms: [
        .macOS(.v15), .iOS(.v18), .tvOS(.v18), .visionOS(.v2)
    ],
    products: [
        .library(name: "VideoForge", targets: ["VideoForge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/arraypress/swift-image-forge.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "VideoForge",
            dependencies: [.product(name: "ImageForge", package: "swift-image-forge")]
        ),
        .testTarget(name: "VideoForgeTests", dependencies: ["VideoForge"]),
    ]
)
