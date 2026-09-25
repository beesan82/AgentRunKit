import Foundation

enum TTSLoudnessMatcher {
    struct Output {
        let audio: Data
        let ranges: [Range<Int>]
        let measurements: [TTSLoudnessMeasurement]
        let summary: TTSLoudnessSummary
    }

    private static let relativeGateLU = 10.0

    static func match(
        segments: [Data],
        boundaries: [TTSBoundary],
        policy: TTSStitchPolicy,
        loudness: TTSLoudnessMatch,
        format: PCMFormat
    ) throws -> Output {
        precondition(segments.count == boundaries.count, "segments and boundaries must be aligned")
        let sampleRate = format.sampleRate
        let layouts = try resolveLayouts(segments: segments, boundaries: boundaries, policy: policy, format: format)
        let chunks = segments.map { decode($0) }
        let readings = chunks.map { TTSLoudnessMeter.integratedLoudness($0, sampleRate: sampleRate) }

        let anchor = computeAnchor(readings.compactMap(\.lufs))
        let maxCorrection = loudness.maxCorrectionDB
        let differentials = readings.map { reading -> Double in
            guard let anchor, let value = reading.lufs else { return 0 }
            return min(maxCorrection, max(-maxCorrection, anchor - value))
        }

        let gained = zip(chunks, differentials).map { scaled($0.0, byDB: $0.1) }
        let (program, byteRanges) = try assemble(gained, layouts: layouts)

        var assembled = program
        var targetShift = 0.0
        if case let .lufs(target) = loudness.target {
            guard case let .measured(current) = TTSLoudnessMeter.integratedLoudness(assembled, sampleRate: sampleRate)
            else {
                throw TTSError.invalidConfiguration(
                    "loudness target is unreachable: the program has no measurable loudness"
                )
            }
            targetShift = target - current
            assembled = scaled(assembled, byDB: targetShift)
        }

        let peakBeforeTrim = TTSLoudnessMeter.truePeakDBTP(assembled)
        let trim = min(0, loudness.truePeakCeilingDBTP - peakBeforeTrim)
        if trim < 0 {
            assembled = scaled(assembled, byDB: trim)
        }

        let uniform = targetShift + trim
        let measurements = readings.enumerated().map { index, reading in
            TTSLoudnessMeasurement(integratedLUFS: reading.lufs, appliedGainDB: differentials[index] + uniform)
        }
        let summary = summarize(
            assembled,
            target: loudness.target,
            trim: trim,
            peakBeforeTrim: peakBeforeTrim,
            sampleRate: sampleRate
        )
        return Output(
            audio: encode(assembled),
            ranges: byteRanges,
            measurements: measurements,
            summary: summary
        )
    }

    private static func resolveLayouts(
        segments: [Data],
        boundaries: [TTSBoundary],
        policy: TTSStitchPolicy,
        format: PCMFormat
    ) throws -> [PCMSeam.Layout] {
        var planner = try PCMSeam.Planner(format: format, policy: policy, totalSegments: segments.count)
        var layouts: [PCMSeam.Layout] = []
        layouts.reserveCapacity(segments.count)
        for index in segments.indices {
            try layouts.append(planner.next(audio: segments[index], trailingBoundary: boundaries[index]))
        }
        return layouts
    }

    private static func summarize(
        _ program: [Double],
        target: TTSLoudnessMatch.Target,
        trim: Double,
        peakBeforeTrim: Double,
        sampleRate: Int
    ) -> TTSLoudnessSummary {
        let finalPeak = peakBeforeTrim + trim
        let requested: Double? = if case let .lufs(value) = target { value } else { nil }
        return TTSLoudnessSummary(
            achievedLUFS: TTSLoudnessMeter.integratedLoudness(program, sampleRate: sampleRate).lufs,
            requestedTargetLUFS: requested,
            appliedTrimDB: trim,
            truePeakDBTP: finalPeak.isFinite ? finalPeak : nil
        )
    }

    private static func computeAnchor(_ measured: [Double]) -> Double? {
        guard !measured.isEmpty else { return nil }
        let provisional = median(measured)
        let included = measured.filter { $0 >= provisional - relativeGateLU }
        return median(included)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let count = sorted.count
        if count.isMultiple(of: 2) {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        }
        return sorted[count / 2]
    }

    private static func scaled(_ samples: [Double], byDB decibels: Double) -> [Double] {
        guard decibels != 0 else { return samples }
        let gain = pow(10.0, decibels / 20.0)
        return samples.map { $0 * gain }
    }

    private static func assemble(
        _ chunks: [[Double]],
        layouts: [PCMSeam.Layout]
    ) throws -> (program: [Double], ranges: [Range<Int>]) {
        var program: [Double] = []
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(chunks.count)
        for (chunk, layout) in zip(chunks, layouts) {
            guard chunk.count == layout.frameCount else {
                throw TTSError.invalidConfiguration("loudness matching requires mono (1-channel) 16-bit PCM")
            }
            var body = chunk
            if layout.fadeInFrames > 0 || layout.fadeOutFrames > 0 {
                applyEdgeFades(&body, fadeIn: layout.fadeInFrames, fadeOut: layout.fadeOutFrames)
            }
            program.append(contentsOf: repeatElement(0.0, count: layout.leadingSilenceFrames))
            program.append(contentsOf: body)
            ranges.append(layout.byteRange)
        }
        return (program, ranges)
    }

    private static func applyEdgeFades(_ samples: inout [Double], fadeIn: Int, fadeOut: Int) {
        guard fadeIn > 0 || fadeOut > 0, !samples.isEmpty else { return }
        if fadeIn > 0 {
            for step in 0 ..< fadeIn {
                samples[step] *= PCMSeam.fadeGain(step: step, fade: fadeIn)
            }
        }
        if fadeOut > 0 {
            for offset in 0 ..< fadeOut {
                samples[samples.count - 1 - offset] *= PCMSeam.fadeGain(step: offset, fade: fadeOut)
            }
        }
    }

    private static func decode(_ data: Data) -> [Double] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw -> [Double] in
            let bytes = raw.bindMemory(to: UInt8.self)
            var out = [Double](repeating: 0, count: count)
            for index in 0 ..< count {
                let low = UInt16(bytes[index * 2])
                let high = UInt16(bytes[index * 2 + 1])
                out[index] = Double(Int16(bitPattern: low | (high << 8))) / 32768.0
            }
            return out
        }
    }

    private static func encode(_ samples: [Double]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let bits = UInt16(bitPattern: Int16((clamped * 32767.0).rounded()))
            data.append(UInt8(bits & 0x00FF))
            data.append(UInt8(bits >> 8))
        }
        return data
    }
}
