//
//  TestClips+Metadata.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  A clip with a timed-metadata track, as a phone writes one beside its
//  video: one boxed sample every half second, each naming itself, linked
//  to the video it describes (`cdsc`).
//

import AVFoundation
import CoreMedia
import Foundation

extension TestClips {

    /// The identifier every marker is written under.
    static let markerIdentifier = AVMetadataIdentifier("mdta/com.arraypress.marker")

    /// Three seconds of 320×240 video with six 0.5 s metadata samples,
    /// `m0` to `m5`, linked to the video.
    static func writeMetadataMovie(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let (width, height, frames) = (320, 240, 90)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = false
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(video)

        var format: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: nil, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [[
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: markerIdentifier.rawValue,
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_UTF8 as String,
            ]] as CFArray, formatDescriptionOut: &format)
        let metadata = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        metadata.expectsMediaDataInRealTime = false
        let groups = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadata)
        writer.add(metadata)
        metadata.addTrackAssociation(withTrackOf: video, type: AVAssetTrack.AssociationType.metadataReferent.rawValue)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let queue = DispatchQueue(label: "test.metadata")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var frame = 0, marker = 0, finished = 0
            let finish = {
                finished += 1
                if finished == 2 { done.resume() }
            }
            video.requestMediaDataWhenReady(on: queue) {
                while video.isReadyForMoreMediaData {
                    guard frame < frames else { video.markAsFinished(); finish(); return }
                    guard let pool = pixels.pixelBufferPool else { continue }
                    var buffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                    guard let buffer else { continue }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 2), CVPixelBufferGetDataSize(buffer))
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    pixels.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
                    frame += 1
                }
            }
            metadata.requestMediaDataWhenReady(on: queue) {
                while metadata.isReadyForMoreMediaData {
                    guard marker < 6 else { metadata.markAsFinished(); finish(); return }
                    let item = AVMutableMetadataItem()
                    item.identifier = markerIdentifier
                    item.dataType = kCMMetadataBaseDataType_UTF8 as String
                    item.value = "m\(marker)" as NSString
                    groups.append(AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(
                        start: CMTime(value: CMTimeValue(marker * 500), timescale: 1000),
                        duration: CMTime(value: 500, timescale: 1000))))
                    marker += 1
                }
            }
        }
        await writer.finishWriting()
    }

    /// Every metadata sample of a file as the RAW reader gives it — media
    /// time, edits ignored, as ffmpeg reads it — with its marker's value.
    static func metadataSamples(of url: URL) async throws -> [(start: Double, end: Double, value: String)] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .metadata).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var samples: [(start: Double, end: Double, value: String)] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(buffer) > 0,
                  let group = AVTimedMetadataGroup(sampleBuffer: buffer) else { continue }
            let value = group.items.first?.stringValue ?? ""
            let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            samples.append((start, start + CMSampleBufferGetDuration(buffer).seconds, value))
        }
        return samples
    }
}
