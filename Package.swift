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
        // The colour and tone engine, shared with `img` so a look applied to a
        // still and to a clip is the same look.
        .package(url: "https://github.com/arraypress/swift-video-grade.git", from: "0.1.1"),
        // The cue model and the SRT/WebVTT reading and writing the caption
        // tools already share, so a subtitle track in and out of a movie is
        // the same cue everywhere.
        .package(url: "https://github.com/arraypress/swift-subtitle-kit.git", from: "0.1.0"),
        // Landmark-driven face retouching, for `beautify`.
        .package(url: "https://github.com/arraypress/swift-face-beauty.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "VideoForge",
            dependencies: [
                .product(name: "ImageForge", package: "swift-image-forge"),
                .product(name: "VideoGrade", package: "swift-video-grade"),
                .product(name: "SubtitleKit", package: "swift-subtitle-kit"),
                .product(name: "FaceBeauty", package: "swift-face-beauty"),
            ]
        ),
        // Resources holds one synthetic portrait (imagine --fast), for the
        // picture-in-picture tests to find a face in.
        .testTarget(name: "VideoForgeTests", dependencies: ["VideoForge"], resources: [.copy("Resources")]),
    ]
)

// Swift 7's import rule, today: a file must import every module whose members
// it uses, rather than leaning on another file's imports.
for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}
