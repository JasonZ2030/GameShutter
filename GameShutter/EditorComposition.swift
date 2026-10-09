//
//  EditorComposition.swift
//  GameShutter
//
//  Model + AVFoundation plumbing for the video editor: the clip list, turning
//  it into a playable/exportable composition, and rendering the ending card.
//

import UIKit
import AVFoundation

// One segment on the timeline: a time range of a source file. Splitting a clip
// produces two EditorClips over the same asset with adjacent ranges.
struct EditorClip {
    let id = UUID()
    let asset: AVURLAsset
    var timeRange: CMTimeRange
    // The generated GameShutter ending card — always kept last, can't be split.
    var isEnding = false

    var duration: CMTime { return timeRange.duration }
}

struct EditorAudio {
    let asset: AVURLAsset
    let name: String
}

// Everything undo/redo snapshots.
struct EditorProject {
    var clips: [EditorClip] = []
    var audio: EditorAudio?

    var duration: CMTime {
        return clips.reduce(CMTime.zero) { CMTimeAdd($0, $1.duration) }
    }

    var hasEnding: Bool { return clips.last?.isEnding == true }

    // Start time of each clip on the composition timeline.
    var clipStarts: [CMTime] {
        var starts: [CMTime] = []
        var t = CMTime.zero
        for clip in clips {
            starts.append(t)
            t = CMTimeAdd(t, clip.duration)
        }
        return starts
    }

    // Index of the clip under timeline time `t` (the last clip if t == duration).
    func clipIndex(at t: CMTime) -> Int? {
        var start = CMTime.zero
        for (i, clip) in clips.enumerated() {
            let end = CMTimeAdd(start, clip.duration)
            if t < end || (i == clips.count - 1 && t <= end) { return i }
            start = end
        }
        return nil
    }

    // New clips always go before the ending card, if there is one.
    mutating func append(_ newClips: [EditorClip]) {
        let insertAt = hasEnding ? clips.count - 1 : clips.count
        clips.insert(contentsOf: newClips, at: insertAt)
    }

    // Splits the (non-ending) clip under `t` in two. Returns false if `t` is too
    // close to either edge of that clip to leave a usable piece.
    mutating func split(at t: CMTime) -> Bool {
        guard let index = clipIndex(at: t), !clips[index].isEnding else { return false }
        let clip = clips[index]
        let offset = CMTimeSubtract(t, clipStarts[index])
        let minPiece = CMTime(value: 1, timescale: 10)
        guard offset >= minPiece, CMTimeSubtract(clip.duration, offset) >= minPiece else { return false }
        let first = EditorClip(asset: clip.asset, timeRange: CMTimeRange(start: clip.timeRange.start, duration: offset))
        let second = EditorClip(asset: clip.asset,
                                timeRange: CMTimeRange(start: CMTimeAdd(clip.timeRange.start, offset),
                                                       duration: CMTimeSubtract(clip.duration, offset)))
        clips.replaceSubrange(index...index, with: [first, second])
        return true
    }
}

enum EditorCompositionBuilder {
    struct Result {
        let composition: AVMutableComposition
        let videoComposition: AVVideoComposition
    }

    // Clips are concatenated on one video track (plus one track for their own
    // audio). Frames are composited with Core Image: each one is turned upright
    // per its source clip's preferredTransform, then scaled to fit, letterboxed
    // on black, into the first clip's upright size — so footage of mixed
    // sizes/orientations still plays as one video. (An instruction-based
    // AVMutableVideoComposition — even AVFoundation's own auto-generated one —
    // stalled AVPlayer playback at rate 0 in the iOS 26 simulator; the CI
    // handler path plays and exports.) Background audio, if any, is laid from 0
    // and trimmed to the video's length.
    static func build(_ project: EditorProject) -> Result? {
        guard !project.clips.isEmpty else { return nil }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let clipAudioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)

        let renderSize = project.clips.lazy
            .compactMap { $0.asset.tracks(withMediaType: .video).first }
            .map { uprightSize(of: $0) }
            .first ?? CGSize(width: 1920, height: 1080)

        // (start time, orientation) per inserted clip, for the frame handler.
        var segments: [(start: CMTime, orientation: CGImagePropertyOrientation)] = []
        var cursor = CMTime.zero
        for clip in project.clips {
            guard let sourceVideo = clip.asset.tracks(withMediaType: .video).first else { continue }
            do {
                try videoTrack.insertTimeRange(clip.timeRange, of: sourceVideo, at: cursor)
            } catch {
                print("Editor: couldn't insert clip video: \(error)")
                continue
            }
            if let sourceAudio = clip.asset.tracks(withMediaType: .audio).first {
                try? clipAudioTrack?.insertTimeRange(clip.timeRange, of: sourceAudio, at: cursor)
            }
            segments.append((cursor, orientation(of: sourceVideo.preferredTransform)))
            cursor = CMTimeAdd(cursor, clip.duration)
        }
        // An audio track with no segments (every clip silent) can stall playback/export.
        if let clipAudioTrack = clipAudioTrack, clipAudioTrack.segments.isEmpty {
            composition.removeTrack(clipAudioTrack)
        }

        if let audio = project.audio, let sourceAudio = audio.asset.tracks(withMediaType: .audio).first,
           let musicTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            let length = CMTimeMinimum(audio.asset.duration, cursor)
            try? musicTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: sourceAudio, at: .zero)
        }

        let renderRect = CGRect(origin: .zero, size: renderSize)
        let background = CIImage(color: .black).cropped(to: renderRect)
        let videoComposition = AVMutableVideoComposition(asset: composition) { request in
            let orientation = segments.last { $0.start <= request.compositionTime }?.orientation ?? .up
            var image = request.sourceImage.oriented(orientation)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else {
                request.finish(with: background, context: nil)
                return
            }
            let scale = min(renderSize.width / extent.width, renderSize.height / extent.height)
            image = image
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: (renderSize.width - extent.width * scale) / 2,
                                                   y: (renderSize.height - extent.height * scale) / 2))
            request.finish(with: image.composited(over: background).cropped(to: renderRect), context: nil)
        }
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        return Result(composition: composition, videoComposition: videoComposition)
    }

    static func uprightSize(of track: AVAssetTrack) -> CGSize {
        let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    // The rotation a track's preferredTransform encodes, as the EXIF orientation
    // that makes its frames upright (iPhone/iPad recordings are only ever
    // stored rotated by a multiple of 90°).
    private static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }
}

// Renders (once, then reuses) a short clip of the GameShutter lockup centered on
// Ink, used as the "ending" card.
enum EndingClipRenderer {
    static let duration = CMTime(value: 2, timescale: 1)
    private static let size = CGSize(width: 1920, height: 1080)
    private static let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("gameshutter_ending_v2.mov")

    // `completion` runs on the main thread.
    static func endingAsset(completion: @escaping (AVURLAsset?) -> Void) {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            completion(AVURLAsset(url: fileURL))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = render()
            DispatchQueue.main.async { completion(ok ? AVURLAsset(url: fileURL) : nil) }
        }
    }

    private static func render() -> Bool {
        let partialURL = fileURL.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partialURL)
        guard let writer = try? AVAssetWriter(outputURL: partialURL, fileType: .mov),
              let frame = makeFrame() else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 30
        let frameCount = Int(duration.seconds * Double(fps))
        for i in 0..<frameCount {
            while !input.isReadyForMoreMediaData { usleep(2_000) }
            adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        // The last frame holds until here, so the clip is exactly `duration` long.
        writer.endSession(atSourceTime: duration)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { return false }
        try? FileManager.default.removeItem(at: fileURL)
        return (try? FileManager.default.moveItem(at: partialURL, to: fileURL)) != nil
    }

    private static func makeFrame() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32BGRA, attrs, &buffer)
        guard let pixelBuffer = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                  width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Ink #0E1116
        ctx.setFillColor(red: 0x0E / 255.0, green: 0x11 / 255.0, blue: 0x16 / 255.0, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        if let logo = UIImage(named: "GameShutterWatermark")?.cgImage {
            let width = size.width * 0.45
            let height = width * CGFloat(logo.height) / CGFloat(logo.width)
            ctx.draw(logo, in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                                      width: width, height: height))
        }
        return pixelBuffer
    }
}
