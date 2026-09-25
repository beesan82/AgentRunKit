import Foundation

enum PCMStitcher {
    static func stitch(
        segments: [Data],
        boundaries: [TTSBoundary],
        policy: TTSStitchPolicy,
        format: PCMFormat
    ) throws -> (audio: Data, ranges: [Range<Int>]) {
        precondition(segments.count == boundaries.count, "segments and boundaries must be aligned")
        var planner = try PCMSeam.Planner(format: format, policy: policy, totalSegments: segments.count)
        let bytesPerFrame = format.bytesPerFrame
        var audio = Data()
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(segments.count)
        for index in segments.indices {
            let layout = try planner.next(audio: segments[index], trailingBoundary: boundaries[index])
            var body = segments[index]
            if layout.fadeInFrames > 0 || layout.fadeOutFrames > 0 {
                applyEdgeFades(
                    &body,
                    fadeIn: layout.fadeInFrames,
                    fadeOut: layout.fadeOutFrames,
                    bytesPerFrame: bytesPerFrame
                )
            }
            audio.append(Data(count: layout.leadingSilenceFrames * bytesPerFrame))
            audio.append(body)
            ranges.append(layout.byteRange)
        }
        return (audio, ranges)
    }

    private static func applyEdgeFades(
        _ segment: inout Data,
        fadeIn: Int,
        fadeOut: Int,
        bytesPerFrame: Int
    ) {
        guard fadeIn > 0 || fadeOut > 0 else { return }
        let channels = bytesPerFrame / 2
        let totalFrames = segment.count / bytesPerFrame
        guard totalFrames > 0, channels > 0 else { return }
        var bytes = [UInt8](segment)
        if fadeIn > 0 {
            for frame in 0 ..< fadeIn {
                scaleFrame(
                    &bytes,
                    frame: frame,
                    gain: PCMSeam.fadeGain(step: frame, fade: fadeIn),
                    channels: channels,
                    bytesPerFrame: bytesPerFrame
                )
            }
        }
        if fadeOut > 0 {
            for offset in 0 ..< fadeOut {
                scaleFrame(
                    &bytes,
                    frame: totalFrames - 1 - offset,
                    gain: PCMSeam.fadeGain(step: offset, fade: fadeOut),
                    channels: channels,
                    bytesPerFrame: bytesPerFrame
                )
            }
        }
        segment = Data(bytes)
    }

    private static func scaleFrame(
        _ bytes: inout [UInt8],
        frame: Int,
        gain: Double,
        channels: Int,
        bytesPerFrame: Int
    ) {
        let frameStart = frame * bytesPerFrame
        for channel in 0 ..< channels {
            let low = frameStart + channel * 2
            let sample = Int16(bitPattern: UInt16(bytes[low]) | (UInt16(bytes[low + 1]) << 8))
            let scaled = Int16((Double(sample) * gain).rounded())
            let bits = UInt16(bitPattern: scaled)
            bytes[low] = UInt8(bits & 0x00FF)
            bytes[low + 1] = UInt8(bits >> 8)
        }
    }
}
