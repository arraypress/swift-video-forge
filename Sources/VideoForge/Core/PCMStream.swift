//
//  PCMStream.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  A movie's or a song's sound, decoded to interleaved 32-bit float at the
//  rate and channel count asked for — AVFoundation resamples and up- or
//  down-mixes on the way — handed out a buffer at a time, so an hour of
//  sound is never held at once.
//

import AVFoundation
import Foundation

/// Decoded sound, a buffer at a time.
final class PCMStream {
    let sampleRate: Double
    let channels: Int
    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput

    /// Opens the first sound track of `url`.
    ///
    /// - Parameters:
    ///   - url: The file.
    ///   - rate: The sample rate to decode to; nil keeps the track's.
    ///   - channels: The channel count to decode to; nil keeps the track's.
    /// - Throws: ``VideoForgeError/noAudioTrack(_:)`` or
    ///   ``VideoForgeError/unreadable(_:reason:)``.
    init(_ url: URL, rate: Double? = nil, channels: Int? = nil) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw VideoForgeError.noAudioTrack(url)
        }
        let own = try await Self.format(of: track)
        sampleRate = rate ?? own.rate
        self.channels = channels ?? own.channels
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw VideoForgeError.unreadable(url, reason: error.localizedDescription)
        }
        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: self.channels,
        ])
        decoded.alwaysCopiesSampleData = false
        guard reader.canAdd(decoded) else {
            throw VideoForgeError.unreadable(url, reason: "its sound cannot be decoded")
        }
        reader.add(decoded)
        output = decoded
        guard reader.startReading() else {
            throw VideoForgeError.unreadable(url, reason: reader.error?.localizedDescription ?? "its sound cannot be read")
        }
    }

    /// The next buffer of interleaved frames; nil at the end.
    func next() -> [Float]? {
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            if status == noErr { return samples }
        }
        return nil
    }

    /// Whether reading stopped on an error rather than at the end.
    var failed: Bool { reader.status == .failed }

    /// Everything that is left, in one array.
    func rest() -> [Float] {
        var all: [Float] = []
        while let chunk = next() { all += chunk }
        return all
    }

    /// A sound track's own rate and channel count.
    static func format(of track: AVAssetTrack) async throws -> (rate: Double, channels: Int) {
        let description = try await track.load(.formatDescriptions).first
        let basic = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let rate = basic.map(\.mSampleRate).flatMap { $0 > 0 ? $0 : nil } ?? 48_000
        let channels = basic.map { Int($0.mChannelsPerFrame) }.flatMap { $0 > 0 ? $0 : nil } ?? 2
        return (rate, channels)
    }
}
