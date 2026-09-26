@testable import AgentRunKit
import Foundation
import Testing

private let pcmFormat: PCMFormat = {
    guard let format = PCMFormat(TTSAudioEncoding(.pcm, sampleRate: 24000, channels: 1, bitsPerSample: 16)) else {
        preconditionFailure("test fixture encoding must be valid 16-bit PCM")
    }
    return format
}()

private func pcmTone(amplitude: Double, seconds: Double, freq: Double = 1000) -> Data {
    let count = Int(seconds * 24000)
    var data = Data(capacity: count * 2)
    for index in 0 ..< count {
        let sample = amplitude * sin(2 * .pi * freq * Double(index) / 24000)
        let bits = UInt16(bitPattern: Int16((max(-1.0, min(1.0, sample)) * 32767.0).rounded()))
        data.append(UInt8(bits & 0x00FF))
        data.append(UInt8(bits >> 8))
    }
    return data
}

private func pcmConstant(sample: Int16, frames: Int) -> Data {
    var data = Data(capacity: frames * 2)
    let bits = UInt16(bitPattern: sample)
    for _ in 0 ..< frames {
        data.append(UInt8(bits & 0x00FF))
        data.append(UInt8(bits >> 8))
    }
    return data
}

private func boundaries(_ count: Int) -> [TTSBoundary] {
    (0 ..< count).map { $0 == count - 1 ? .end : .sentence }
}

private func match(
    _ segments: [Data],
    _ loudness: TTSLoudnessMatch,
    boundaries seams: [TTSBoundary]? = nil,
    policy: TTSStitchPolicy = TTSStitchPolicy()
) throws -> TTSLoudnessMatcher.Output {
    try TTSLoudnessMatcher.match(
        segments: segments,
        boundaries: seams ?? boundaries(segments.count),
        policy: policy,
        loudness: loudness,
        format: pcmFormat
    )
}

private func spread(_ values: [Double]) throws -> Double {
    try #require(values.max()) - (try #require(values.min()))
}

private func decodePCM(_ data: Data) -> [Double] {
    let bytes = [UInt8](data)
    return stride(from: 0, to: bytes.count, by: 2).map { index in
        Double(Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))) / 32768.0
    }
}

private func sample(_ data: Data, frame: Int) -> Int16 {
    let index = data.startIndex + frame * 2
    return Int16(bitPattern: UInt16(data[index]) | (UInt16(data[index + 1]) << 8))
}

private func pcmSamples(_ values: [Int16]) -> Data {
    var data = Data(capacity: values.count * 2)
    for value in values {
        let bits = UInt16(bitPattern: value)
        data.append(UInt8(bits & 0x00FF))
        data.append(UInt8(bits >> 8))
    }
    return data
}

private func pcmSpikes(frames: Int) -> Data {
    var samples = [Int16](repeating: 0, count: frames)
    for index in stride(from: 0, to: frames - 12, by: 120) {
        samples[index] = 3000
    }
    return pcmSamples(samples)
}

private func intSamples(_ data: Data) -> [Int16] {
    stride(from: 0, to: data.count, by: 2).map { index in
        Int16(bitPattern: UInt16(data[index]) | (UInt16(data[index + 1]) << 8))
    }
}

private actor ReleaseGate {
    private var isReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func wait() async {
        guard !isReleased else { return }
        precondition(releaseContinuation == nil, "ReleaseGate supports a single waiter")
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }
}

struct TTSLoudnessMatcherTests {
    @Test
    func levelingReducesSpreadAndRespectsTheClamp() throws {
        let segments = [
            pcmTone(amplitude: 0.5, seconds: 1),
            pcmTone(amplitude: 0.25, seconds: 1),
            pcmTone(amplitude: 0.4, seconds: 1),
            pcmTone(amplitude: 0.15, seconds: 1),
        ]
        let output = try match(segments, TTSLoudnessMatch(maxCorrectionDB: 6))
        let measured = output.measurements.compactMap(\.integratedLUFS)
        #expect(measured.count == 4)
        let corrected = try output.measurements.map { try #require($0.integratedLUFS) + $0.appliedGainDB }
        #expect(try spread(corrected) < spread(measured))
        for measurement in output.measurements {
            #expect(abs(measurement.appliedGainDB) <= 6.0 + 1e-9)
        }
    }

    @Test
    func singleChunkAppliesNoDifferentialAndDoesNotCrash() throws {
        let output = try match([pcmTone(amplitude: 0.4, seconds: 1)], TTSLoudnessMatch())
        #expect(output.measurements.count == 1)
        #expect(output.measurements[0].appliedGainDB == 0)
    }

    @Test
    func anchorsToTheRobustMedianSoOneQuietOutlierDoesNotDragTheLoudChunks() throws {
        let segments = [
            pcmTone(amplitude: 0.5, seconds: 1),
            pcmTone(amplitude: 0.45, seconds: 1),
            pcmTone(amplitude: 0.4, seconds: 1),
            pcmTone(amplitude: 0.1, seconds: 1),
        ]
        let output = try match(segments, TTSLoudnessMatch(maxCorrectionDB: 12))
        let measured = try output.measurements.map { try #require($0.integratedLUFS) }
        let mean = measured.reduce(0, +) / Double(measured.count)
        #expect(measured[0] - mean > 3)
        #expect(abs(output.measurements[0].appliedGainDB) < 1.5)
        #expect(abs(output.measurements[1].appliedGainDB) < 1.5)
    }

    @Test
    func absoluteTargetIsReachedWhenTheGuardDoesNotFire() throws {
        let segments = [pcmTone(amplitude: 0.3, seconds: 1.5), pcmTone(amplitude: 0.2, seconds: 1.5)]
        let output = try match(segments, TTSLoudnessMatch(target: .lufs(-23), maxCorrectionDB: 3))
        #expect(output.summary.requestedTargetLUFS == -23)
        let achieved = try #require(output.summary.achievedLUFS)
        #expect(abs(achieved - -23) < 0.6)
        #expect(output.summary.appliedTrimDB == 0)
        let remetered = try #require(
            TTSLoudnessMeter.integratedLoudness(decodePCM(output.audio), sampleRate: 24000).lufs
        )
        #expect(abs(remetered - -23) < 0.6)
        for measurement in output.measurements {
            let level = try #require(measurement.integratedLUFS)
            #expect(abs((level + measurement.appliedGainDB) - achieved) < 0.6)
        }
    }

    @Test
    func absoluteTargetClampedByCeilingIsObservableNotSilent() throws {
        let segments = [pcmTone(amplitude: 0.7, seconds: 1.5), pcmTone(amplitude: 0.7, seconds: 1.5)]
        let output = try match(segments, TTSLoudnessMatch(target: .lufs(-3), truePeakCeilingDBTP: -1))
        #expect(output.summary.appliedTrimDB < 0)
        let achieved = try #require(output.summary.achievedLUFS)
        #expect(achieved < -3)
        let truePeak = try #require(output.summary.truePeakDBTP)
        #expect(truePeak <= -1 + 0.1)
        #expect(TTSLoudnessMeter.truePeakDBTP(decodePCM(output.audio)) <= -1 + 0.1)
    }

    @Test
    func absoluteTargetWithNoMeasurableProgramThrows() {
        let silence = Data(count: 24000 * 2)
        #expect(throws: TTSError.self) {
            _ = try match([silence], TTSLoudnessMatch(target: .lufs(-16)))
        }
    }

    @Test
    func shortLoudChunkIsUnmeasurableButStillPeakGuarded() throws {
        let segments = [
            pcmTone(amplitude: 0.3, seconds: 1),
            pcmTone(amplitude: 0.97, seconds: 0.2),
            pcmTone(amplitude: 0.3, seconds: 1),
        ]
        let output = try match(segments, TTSLoudnessMatch(truePeakCeilingDBTP: -1))
        #expect(output.measurements[1].integratedLUFS == nil)
        #expect(output.summary.appliedTrimDB < 0)
        let truePeak = try #require(output.summary.truePeakDBTP)
        #expect(truePeak <= -1 + 0.1)
        #expect(TTSLoudnessMeter.truePeakDBTP(decodePCM(output.audio)) <= -1 + 0.1)
    }

    @Test
    func clipGuardHoldsTheCeilingAcrossAZeroPauseSeam() throws {
        let hot = pcmTone(amplitude: 0.97, seconds: 1)
        let output = try match(
            [hot, hot],
            TTSLoudnessMatch(truePeakCeilingDBTP: -1),
            boundaries: [.withinSentence, .end]
        )
        let truePeak = try #require(output.summary.truePeakDBTP)
        #expect(truePeak <= -1 + 0.1)
        #expect(TTSLoudnessMeter.truePeakDBTP(decodePCM(output.audio)) <= -1 + 0.1)
    }

    @Test
    func assemblyPlacesRangesContiguouslyWithBoundaryPauses() throws {
        let segments = [pcmTone(amplitude: 0.5, seconds: 1), pcmTone(amplitude: 0.3, seconds: 1)]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(80))
        let output = try match(segments, TTSLoudnessMatch(), boundaries: [.sentence, .end], policy: policy)
        let pauseBytes = try PCMSeam.frameCount(.milliseconds(80), sampleRate: 24000) * 2
        #expect(output.ranges[0] == 0 ..< 24000 * 2)
        #expect(output.ranges[1].lowerBound == output.ranges[0].upperBound + pauseBytes)
        #expect(output.audio.count == output.ranges[1].upperBound)
    }

    @Test
    func plainAndLoudnessLayoutsAgreeOnGapsAndRanges() throws {
        let first = pcmConstant(sample: 8000, frames: 12000) + Data(count: 2400 * 2)
        let second = Data(count: 1200 * 2) + pcmConstant(sample: 8000, frames: 12000)
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(200))
        let plain = try PCMStitcher.stitch(
            segments: [first, second],
            boundaries: [.sentence, .end],
            policy: policy,
            format: pcmFormat
        )
        let matched = try match([first, second], TTSLoudnessMatch(), boundaries: [.sentence, .end], policy: policy)
        #expect(matched.ranges == plain.ranges)
        #expect(matched.audio.count == plain.audio.count)
        #expect(matched.ranges[1].lowerBound - matched.ranges[0].upperBound == 2400)
    }

    @Test
    func plainAndLoudnessPathsAgreeOnFadedOutput() throws {
        let first = pcmConstant(sample: 6000, frames: 6000)
        let second = pcmConstant(sample: -6000, frames: 6000)
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(200), joinFade: .milliseconds(5))
        let plain = try PCMStitcher.stitch(
            segments: [first, second], boundaries: [.sentence, .end], policy: policy, format: pcmFormat
        )
        let matched = try match([first, second], TTSLoudnessMatch(), boundaries: [.sentence, .end], policy: policy)

        #expect(matched.ranges == plain.ranges)
        #expect(matched.audio.count == plain.audio.count)
        #expect(matched.measurements.allSatisfy { $0.appliedGainDB == 0 })
        #expect(matched.ranges[1].lowerBound - matched.ranges[0].upperBound == 9600)

        let plainFirst = plain.audio.subdata(in: plain.ranges[0])
        let plainSecond = plain.audio.subdata(in: plain.ranges[1])
        #expect(sample(plainFirst, frame: 5999) == 0)
        #expect(sample(plainSecond, frame: 0) == 0)
        let unfadedJump = abs(Int(6000) - Int(-6000))
        let plainJump = abs(Int(sample(plainFirst, frame: 5999)) - Int(sample(plainSecond, frame: 0)))
        #expect(plainJump < unfadedJump)
        let fadeFrames = try PCMSeam.frameCount(.milliseconds(5), sampleRate: 24000)
        #expect(plainFirst.prefix((6000 - fadeFrames) * 2) == first.prefix((6000 - fadeFrames) * 2))
        #expect(plainSecond.suffix(from: fadeFrames * 2) == second.suffix(from: fadeFrames * 2))

        let matchedFirst = matched.audio.subdata(in: matched.ranges[0])
        let matchedSecond = matched.audio.subdata(in: matched.ranges[1])
        #expect(abs(Int(sample(matchedFirst, frame: 5999))) <= 1)
        #expect(abs(Int(sample(matchedSecond, frame: 0))) <= 1)
        for (plainBody, matchedBody) in [(plainFirst, matchedFirst), (plainSecond, matchedSecond)] {
            #expect(plainBody.count == matchedBody.count)
            for frame in 0 ..< plainBody.count / 2 {
                let drift = abs(Int(sample(plainBody, frame: frame)) - Int(sample(matchedBody, frame: frame)))
                #expect(drift <= 1)
            }
        }
    }

    @Test
    func neutralSafeHeadroomRoundTripPreservesExactSamples() throws {
        let first = pcmTone(amplitude: 0.7, seconds: 1)
        let second = pcmTone(amplitude: 0.7, seconds: 1)
        let output = try match([first, second], TTSLoudnessMatch(), policy: TTSStitchPolicy())
        #expect(output.measurements.allSatisfy { $0.appliedGainDB == 0 })
        #expect(output.summary.appliedTrimDB == 0)
        #expect(output.audio == first + second)
    }

    @Test
    func chunkInteriorSurvivesFadesAndUnityGainExactly() throws {
        let first = pcmTone(amplitude: 0.4, seconds: 1)
        let second = pcmTone(amplitude: 0.4, seconds: 1)
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(80), joinFade: .milliseconds(5))
        let output = try match([first, second], TTSLoudnessMatch(), boundaries: [.sentence, .end], policy: policy)
        #expect(output.measurements.allSatisfy { $0.appliedGainDB == 0 })
        let fadeFrames = try PCMSeam.frameCount(.milliseconds(5), sampleRate: 24000)
        for (body, source) in [(output.audio.subdata(in: output.ranges[0]), first),
                               (output.audio.subdata(in: output.ranges[1]), second)] {
            #expect(body.count == source.count)
            for frame in (fadeFrames + 200) ..< (body.count / 2 - fadeFrames - 200) {
                #expect(sample(body, frame: frame) == sample(source, frame: frame))
            }
        }
    }

    @Test
    func renderQuantizesTiesAwayFromZero() throws {
        let layout = PCMSeam.Layout(
            frameCount: 3,
            leadingSilenceFrames: 0,
            fadeInFrames: 0,
            fadeOutFrames: 0,
            byteRange: 0 ..< 6
        )
        let rendered = try PCMStitcher.render(
            audio: pcmSamples([1, -1, 3]),
            layout: layout,
            gain: 0.5,
            format: pcmFormat
        )
        #expect(intSamples(rendered) == [1, -1, 2])
    }

    @Test
    func renderSaturatesInsteadOfWrapping() throws {
        let layout = PCMSeam.Layout(
            frameCount: 2,
            leadingSilenceFrames: 0,
            fadeInFrames: 0,
            fadeOutFrames: 0,
            byteRange: 0 ..< 4
        )
        let hot = try PCMStitcher.render(
            audio: pcmSamples([30000, -30000]),
            layout: layout,
            gain: 2,
            format: pcmFormat
        )
        #expect(intSamples(hot) == [32767, -32768])
    }

    @Test
    func unrepresentableCeilingThrowsInsteadOfClipping() {
        #expect(throws: TTSError.self) {
            _ = try match(
                [pcmTone(amplitude: 0.3, seconds: 1.5)],
                TTSLoudnessMatch(truePeakCeilingDBTP: -120)
            )
        }
    }

    @Test
    func absoluteTargetMutedByQuantizationThrows() {
        #expect(throws: TTSError.self) {
            _ = try match(
                [pcmTone(amplitude: 0.3, seconds: 1.5), pcmTone(amplitude: 0.2, seconds: 1.5)],
                TTSLoudnessMatch(target: .lufs(-100))
            )
        }
    }

    @Test
    func silentMedianProgramRendersSilenceWithNilSummary() throws {
        let silence = Data(count: 24000 * 2)
        let output = try match([silence, silence], TTSLoudnessMatch(), policy: TTSStitchPolicy())
        #expect(output.audio == silence + silence)
        #expect(output.measurements.allSatisfy { $0.integratedLUFS == nil && $0.appliedGainDB == 0 })
        #expect(output.summary.achievedLUFS == nil)
        #expect(output.summary.requestedTargetLUFS == nil)
        #expect(output.summary.appliedTrimDB == 0)
        #expect(output.summary.truePeakDBTP == nil)
    }

    @Test
    func summaryMatchesRemeasurementOfReturnedBytes() throws {
        let segments = [pcmTone(amplitude: 0.3, seconds: 1.5), pcmTone(amplitude: 0.2, seconds: 1.5)]
        let output = try match(segments, TTSLoudnessMatch(target: .lufs(-23), maxCorrectionDB: 3))
        let remeteredLUFS = try #require(
            TTSLoudnessMeter.integratedLoudness(decodePCM(output.audio), sampleRate: 24000).lufs
        )
        #expect(try abs(#require(output.summary.achievedLUFS) - remeteredLUFS) < 1e-6)
        let remeteredPeak = TTSLoudnessMeter.truePeakDBTP(decodePCM(output.audio))
        #expect(try abs(#require(output.summary.truePeakDBTP) - remeteredPeak) < 1e-8)
    }

    @Test
    func peakGuardHoldsCeilingStrictlyAfterQuantization() throws {
        let hot = pcmTone(amplitude: 0.97, seconds: 1)
        let output = try match([hot, hot], TTSLoudnessMatch(truePeakCeilingDBTP: -1))
        #expect(output.summary.appliedTrimDB < 0)
        #expect(try #require(output.summary.truePeakDBTP) <= -1.0)
        #expect(TTSLoudnessMeter.truePeakDBTP(decodePCM(output.audio)) <= -1.0)
    }

    @Test
    func leveledBodiesMeasureNarrowerSpread() throws {
        let segments = [
            pcmTone(amplitude: 0.5, seconds: 1),
            pcmTone(amplitude: 0.25, seconds: 1),
            pcmTone(amplitude: 0.4, seconds: 1),
            pcmTone(amplitude: 0.15, seconds: 1),
        ]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(80))
        let output = try match(
            segments,
            TTSLoudnessMatch(maxCorrectionDB: 6),
            boundaries: [.sentence, .sentence, .sentence, .end],
            policy: policy
        )
        let inputLevels = try segments.map { segment in
            try #require(TTSLoudnessMeter.integratedLoudness(decodePCM(segment), sampleRate: 24000).lufs)
        }
        let bodyLevels = try output.ranges.map { range in
            let body = output.audio.subdata(in: range)
            return try #require(TTSLoudnessMeter.integratedLoudness(decodePCM(body), sampleRate: 24000).lufs)
        }
        #expect(bodyLevels.count == 4)
        #expect(try spread(bodyLevels) < spread(inputLevels))
    }

    @Test(arguments: [-90.0, -89.0, -88.0])
    func nearMarginCeilingThatErasesSignalThrows(ceiling: Double) {
        do {
            _ = try match(
                [pcmTone(amplitude: 0.3, seconds: 1)],
                TTSLoudnessMatch(truePeakCeilingDBTP: ceiling),
                policy: TTSStitchPolicy()
            )
            Issue.record("expected TTSError.invalidConfiguration for ceiling \(ceiling)")
        } catch let error as TTSError {
            guard case .invalidConfiguration = error else {
                Issue.record("expected TTSError.invalidConfiguration, got \(error)")
                return
            }
        } catch {
            Issue.record("expected TTSError, got \(type(of: error)): \(error)")
        }
    }

    @Test
    func nearMarginCeilingKeepsLegitimateSilence() throws {
        let silence = Data(count: 24000 * 2)
        let output = try match(
            [silence],
            TTSLoudnessMatch(truePeakCeilingDBTP: -90),
            policy: TTSStitchPolicy()
        )
        #expect(output.audio == silence)
        #expect(output.summary.achievedLUFS == nil)
        #expect(output.summary.truePeakDBTP == nil)
    }

    @Test
    func activeTrimThatPreservesSignalSucceeds() throws {
        let tone = pcmTone(amplitude: 0.3, seconds: 1)
        let output = try match(
            [tone],
            TTSLoudnessMatch(truePeakCeilingDBTP: -60),
            policy: TTSStitchPolicy()
        )
        #expect(output.summary.appliedTrimDB < 0)
        #expect(try #require(output.summary.truePeakDBTP) <= -60.0)
        #expect(output.audio.contains { $0 != 0 })
    }

    @Test
    func matchingHonorsTaskCancellation() async throws {
        let segments = [pcmTone(amplitude: 0.3, seconds: 10), pcmTone(amplitude: 0.2, seconds: 10)]
        let gate = ReleaseGate()
        let task = Task {
            await gate.wait()
            return try match(segments, TTSLoudnessMatch(target: .lufs(-23)))
        }
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}

extension TTSLoudnessMatcherTests {
    @Test
    func recentMatchingAnchorsToTheLatestFiveMeasurableChunks() throws {
        let levels = [0.0, -2, -4, -6, -8, -10]
        let segments = levels.map { pcmTone(amplitude: 0.5 * pow(10.0, $0 / 20.0), seconds: 1) }
        let output = try match(segments, TTSLoudnessMatch(target: .recentMedian, maxCorrectionDB: 6))
        let expected = [0.0, 1, 2, 3, 4, 4]
        for (index, measurement) in output.measurements.enumerated() {
            #expect(measurement.integratedLUFS != nil)
            #expect(abs(measurement.appliedGainDB - expected[index]) < 0.25)
        }
    }

    @Test
    func recentMatchingIgnoresSilentAndShortObservations() throws {
        let segments = [
            pcmTone(amplitude: 0.5, seconds: 1),
            Data(count: 24000 * 2),
            pcmTone(amplitude: 0.7, seconds: 1),
            pcmTone(amplitude: 0.5, seconds: 0.2),
            pcmTone(amplitude: 0.5, seconds: 1),
        ]
        let output = try match(segments, TTSLoudnessMatch(target: .recentMedian))
        #expect(output.measurements[1].integratedLUFS == nil)
        #expect(output.measurements[3].integratedLUFS == nil)
        #expect(output.measurements[0].appliedGainDB == 0)
        #expect(output.measurements[1].appliedGainDB == 0)
        #expect(output.measurements[3].appliedGainDB == 0)
        #expect(output.measurements[4].appliedGainDB == 0)
        #expect(abs(output.measurements[2].appliedGainDB + 1.46) < 0.2)
    }

    @Test
    func recentHistorySkipsUnmeasurableChunksWhenEvicting() throws {
        let levels = [0.0, -2, -4, -6, -8]
        var segments = levels.map { pcmTone(amplitude: 0.5 * pow(10.0, $0 / 20.0), seconds: 1) }
        segments.append(Data(count: 24000 * 2))
        segments.append(pcmTone(amplitude: 0.5, seconds: 0.2))
        segments.append(pcmTone(amplitude: 0.5 * pow(10.0, -10.0 / 20.0), seconds: 1))
        let output = try match(segments, TTSLoudnessMatch(target: .recentMedian, maxCorrectionDB: 6))
        #expect(output.measurements[5].integratedLUFS == nil)
        #expect(output.measurements[6].integratedLUFS == nil)
        #expect(abs(output.measurements[7].appliedGainDB - 4) < 0.25)
    }

    @Test
    func recentMatchingClampsCorrectionToTheConfiguredBound() throws {
        let loud = pcmTone(amplitude: 0.5, seconds: 1)
        let quiet = pcmTone(amplitude: 0.5 * pow(10.0, -10.0 / 20.0), seconds: 1)
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(100))
        let boost = try match(
            [loud, quiet],
            TTSLoudnessMatch(target: .recentMedian, maxCorrectionDB: 3),
            boundaries: [.sentence, .end],
            policy: policy
        )
        #expect(boost.measurements[1].appliedGainDB == 3)
        let cut = try match(
            [quiet, loud],
            TTSLoudnessMatch(target: .recentMedian, maxCorrectionDB: 3),
            boundaries: [.sentence, .end],
            policy: policy
        )
        #expect(cut.measurements[1].appliedGainDB == -3)
    }

    @Test
    func recentMatchingAttenuatesAHotShortChunkUnderTheCeiling() throws {
        let segments = [pcmTone(amplitude: 0.3, seconds: 1), pcmTone(amplitude: 0.97, seconds: 0.2)]
        let output = try match(segments, TTSLoudnessMatch(target: .recentMedian, truePeakCeilingDBTP: -1))
        #expect(output.measurements[0].appliedGainDB == 0)
        #expect(output.measurements[1].integratedLUFS == nil)
        #expect(output.measurements[1].appliedGainDB < 0)
        #expect(try #require(output.summary.truePeakDBTP) <= -1.0)
        #expect(TTSLoudnessMeter.truePeakDBTP(decodePCM(output.audio)) <= -1.0)
    }

    @Test
    func recentZeroGapIntersampleJoinHoldsTheCeiling() throws {
        let hot = pcmConstant(sample: 30000, frames: 12000)
        let cold = pcmConstant(sample: -30000, frames: 12000)
        let output = try match(
            [hot, cold],
            TTSLoudnessMatch(target: .recentMedian, truePeakCeilingDBTP: -1),
            boundaries: [.withinSentence, .end]
        )
        #expect(output.measurements[0].appliedGainDB < 0)
        #expect(output.measurements[1].appliedGainDB < output.measurements[0].appliedGainDB)
        #expect(try #require(output.summary.truePeakDBTP) <= -1.0)
        #expect(TTSLoudnessMeter.truePeakDBTP(decodePCM(output.audio)) <= -1.0)
        let unguarded = try PCMStitcher.stitch(
            segments: [hot, cold],
            boundaries: [.withinSentence, .end],
            policy: TTSStitchPolicy(),
            format: pcmFormat
        )
        #expect(TTSLoudnessMeter.truePeakDBTP(decodePCM(unguarded.audio)) > -1.0)
    }

    @Test
    func recentPerBodyErasureThrowsDespitePriorEmittedAudio() {
        #expect(throws: TTSError.self) {
            _ = try match(
                [pcmSpikes(frames: 4800), pcmConstant(sample: 3000, frames: 4800)],
                TTSLoudnessMatch(target: .recentMedian, truePeakCeilingDBTP: -87),
                policy: TTSStitchPolicy()
            )
        }
    }

    @Test
    func recentSilentBodyAtTheSameCeilingRemainsValid() throws {
        let spikes = pcmSpikes(frames: 4800)
        let silence = Data(count: 4800 * 2)
        let output = try match(
            [spikes, silence],
            TTSLoudnessMatch(target: .recentMedian, truePeakCeilingDBTP: -87),
            policy: TTSStitchPolicy()
        )
        #expect(output.measurements[1].appliedGainDB == 0)
        #expect(output.summary.truePeakDBTP != nil)
        #expect(output.audio.subdata(in: output.ranges[1]) == silence)
        #expect(output.audio.contains { $0 != 0 })
    }

    @Test
    func recentNeutralRoundTripPreservesSamplesAndRanges() throws {
        let first = pcmTone(amplitude: 0.5, seconds: 1)
        let second = pcmTone(amplitude: 0.5, seconds: 1)
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(80))
        let output = try match(
            [first, second],
            TTSLoudnessMatch(target: .recentMedian),
            boundaries: [.sentence, .end],
            policy: policy
        )
        #expect(output.measurements.allSatisfy { $0.appliedGainDB == 0 })
        let gapBytes = try PCMSeam.frameCount(.milliseconds(80), sampleRate: 24000) * 2
        #expect(output.ranges[0] == 0 ..< 24000 * 2)
        #expect(output.ranges[1].lowerBound == output.ranges[0].upperBound + gapBytes)
        #expect(output.audio.count == output.ranges[1].upperBound)
        #expect(output.audio.subdata(in: output.ranges[0]) == first)
        #expect(output.audio.subdata(in: output.ranges[1]) == second)
    }

    @Test
    func recentCompletedRenderingMatchesTheRunningProcessor() throws {
        let segments = [
            pcmTone(amplitude: 0.5, seconds: 1),
            pcmTone(amplitude: 0.25, seconds: 1),
            pcmTone(amplitude: 0.4, seconds: 0.15),
        ]
        let seams = boundaries(segments.count)
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(80), joinFade: .milliseconds(5))
        let loudness = TTSLoudnessMatch(target: .recentMedian, maxCorrectionDB: 6)
        let completed = try match(segments, loudness, boundaries: seams, policy: policy)
        var running = try TTSLoudnessMatcher.Running(
            format: pcmFormat,
            policy: policy,
            loudness: loudness,
            totalSegments: segments.count
        )
        var audio = Data()
        var ranges: [Range<Int>] = []
        var measurements: [TTSLoudnessMeasurement] = []
        for (index, segment) in segments.enumerated() {
            let processed = try running.process(audio: segment, trailingBoundary: seams[index])
            audio.append(processed.audio)
            ranges.append(processed.range)
            measurements.append(processed.measurement)
        }
        #expect(audio == completed.audio)
        #expect(ranges == completed.ranges)
        #expect(measurements == completed.measurements)
        let repeated = try match(segments, loudness, boundaries: seams, policy: policy)
        #expect(repeated.audio == completed.audio)
        #expect(repeated.ranges == completed.ranges)
        #expect(repeated.measurements == completed.measurements)
        #expect(repeated.summary == completed.summary)
    }

    @Test
    func recentSummaryDescribesDeliveredBytesWithNoUniformTrim() throws {
        let segments = [pcmTone(amplitude: 0.3, seconds: 1.5), pcmTone(amplitude: 0.2, seconds: 1.5)]
        let output = try match(segments, TTSLoudnessMatch(target: .recentMedian))
        #expect(output.summary.requestedTargetLUFS == nil)
        #expect(output.summary.appliedTrimDB == 0)
        let remeteredLUFS = try #require(
            TTSLoudnessMeter.integratedLoudness(decodePCM(output.audio), sampleRate: 24000).lufs
        )
        #expect(try abs(#require(output.summary.achievedLUFS) - remeteredLUFS) < 1e-6)
        let remeteredPeak = TTSLoudnessMeter.truePeakDBTP(decodePCM(output.audio))
        #expect(try abs(#require(output.summary.truePeakDBTP) - remeteredPeak) < 1e-8)
    }

    @Test
    func recentSummaryAccountsForTheFinalVirtualTail() throws {
        let constant = pcmConstant(sample: 30000, frames: 12000)
        let output = try match(
            [constant],
            TTSLoudnessMatch(target: .recentMedian, truePeakCeilingDBTP: 0),
            policy: TTSStitchPolicy()
        )
        let peak = try #require(output.summary.truePeakDBTP)
        #expect(peak <= 0)
        #expect(output.measurements[0].appliedGainDB < 0)
        let samplePeak = try 20 * log10(Double(#require(intSamples(output.audio).max())) / 32768)
        #expect(peak > samplePeak + 0.9)
    }

    @Test
    func recentSilentBodyAfterAHotJoinEmitsSilence() throws {
        let silence = pcmSamples([Int16](repeating: 0, count: 11))
        let segments = [pcmSamples([30000]), pcmSamples([-30000, -30000]), silence]
        let output = try match(
            segments,
            TTSLoudnessMatch(target: .recentMedian, truePeakCeilingDBTP: -3),
            boundaries: [.withinSentence, .withinSentence, .end]
        )
        #expect(output.audio.subdata(in: output.ranges[2]) == silence)
        #expect(output.measurements[2].appliedGainDB == 0)
        #expect(try #require(output.summary.truePeakDBTP) <= -3.0)
    }

    @Test
    func recentBoundarySelectionKeepsSafeNonzeroAudio() throws {
        let quietTone = pcmTone(amplitude: 0.02, seconds: 1) + pcmSamples([Int16](repeating: 0, count: 11))
        let finalBody = pcmSamples([4, 6, -9])
            + pcmSamples([Int16](repeating: 0, count: 11))
            + pcmTone(amplitude: 0.5, seconds: 1)
        let segments = [
            quietTone,
            quietTone,
            quietTone,
            pcmSamples([30000]),
            pcmSamples([-30000, -30000]),
            finalBody,
        ]
        let output = try match(
            segments,
            TTSLoudnessMatch(target: .recentMedian, maxCorrectionDB: 14, truePeakCeilingDBTP: -3),
            boundaries: [.withinSentence, .withinSentence, .withinSentence, .withinSentence, .withinSentence, .end]
        )
        #expect(TTSLoudnessMeter.truePeakDBTP(decodePCM(output.audio)) <= -3.0)
        #expect(try #require(output.summary.truePeakDBTP) <= -3.0)
        #expect(output.audio.subdata(in: output.ranges[5]).contains { $0 != 0 })
        #expect(output.measurements[5].appliedGainDB < 0)
    }

    @Test
    func recentDeliveredBodyLevelsFollowAppliedGains() throws {
        let levels = [0.0, -2, -4, -6, -8]
        var segments = levels.map { pcmTone(amplitude: 0.5 * pow(10.0, $0 / 20.0), seconds: 1) }
        segments.append(Data(count: 24000 * 2))
        segments.append(pcmTone(amplitude: 0.5, seconds: 0.2))
        segments.append(pcmTone(amplitude: 0.5 * pow(10.0, -10.0 / 20.0), seconds: 1))
        let output = try match(segments, TTSLoudnessMatch(target: .recentMedian, maxCorrectionDB: 6))
        for (index, measurement) in output.measurements.enumerated() {
            guard measurement.integratedLUFS != nil else { continue }
            let original = try #require(
                TTSLoudnessMeter.integratedLoudness(decodePCM(segments[index]), sampleRate: 24000).lufs
            )
            let body = decodePCM(output.audio.subdata(in: output.ranges[index]))
            let delivered = try #require(TTSLoudnessMeter.integratedLoudness(body, sampleRate: 24000).lufs)
            #expect(abs((delivered - original) - measurement.appliedGainDB) < 0.3)
        }
        let loud = pcmTone(amplitude: 0.5, seconds: 1)
        let quiet = pcmTone(amplitude: 0.5 * pow(10.0, -10.0 / 20.0), seconds: 1)
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(100))
        for (pair, expected) in [([loud, quiet], 3.0), ([quiet, loud], -3.0)] {
            let clamped = try match(
                pair,
                TTSLoudnessMatch(target: .recentMedian, maxCorrectionDB: 3),
                boundaries: [.sentence, .end],
                policy: policy
            )
            #expect(clamped.measurements[1].appliedGainDB == expected)
            let original = try #require(
                TTSLoudnessMeter.integratedLoudness(decodePCM(pair[1]), sampleRate: 24000).lufs
            )
            let body = decodePCM(clamped.audio.subdata(in: clamped.ranges[1]))
            let delivered = try #require(TTSLoudnessMeter.integratedLoudness(body, sampleRate: 24000).lufs)
            #expect(abs((delivered - original) - expected) < 0.3)
        }
    }

    @Test
    func recentLongInsertedGapKeepsBodySignalTrackingBounded() throws {
        let tone = pcmTone(amplitude: 0.3, seconds: 1)
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(500))
        let output = try match(
            [tone, tone],
            TTSLoudnessMatch(target: .recentMedian),
            boundaries: [.sentence, .end],
            policy: policy
        )
        let gapBytes = try PCMSeam.frameCount(.milliseconds(500), sampleRate: 24000) * 2
        #expect(output.ranges[0] == 0 ..< 24000 * 2)
        #expect(output.ranges[1].lowerBound == output.ranges[0].upperBound + gapBytes)
        #expect(output.audio.count == output.ranges[1].upperBound)
        #expect(output.audio.subdata(in: output.ranges[0]).contains { $0 != 0 })
        #expect(output.audio.subdata(in: output.ranges[1]).contains { $0 != 0 })
    }

    @Test
    func recentSilentBodyAtALongInsertedGapIsPreserved() throws {
        let silence = Data(count: 100 * 2)
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(500))
        let output = try match(
            [pcmTone(amplitude: 0.3, seconds: 1), silence],
            TTSLoudnessMatch(target: .recentMedian),
            boundaries: [.sentence, .end],
            policy: policy
        )
        let gapFrames = try PCMSeam.frameCount(.milliseconds(500), sampleRate: 24000) - 100
        #expect(output.ranges[1].lowerBound == output.ranges[0].upperBound + gapFrames * 2)
        #expect(output.audio.count == output.ranges[1].upperBound)
        #expect(output.audio.subdata(in: output.ranges[1]) == silence)
    }

    @Test
    func recentSelectionPreservesBodySignalBeyondTheHead() throws {
        let body = pcmSamples([1000]) + pcmSamples([Int16](repeating: 0, count: 10)) + pcmSamples([1500])
        let output = try match(
            [pcmSamples([30000]), pcmSamples([-30000, -30000]), body],
            TTSLoudnessMatch(target: .recentMedian, truePeakCeilingDBTP: -3),
            boundaries: [.withinSentence, .withinSentence, .end]
        )
        let final = intSamples(output.audio.subdata(in: output.ranges[2]))
        #expect(final == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        #expect(try #require(output.summary.truePeakDBTP) <= -3.0)
    }

    @Test
    func recentFadedHeadEmitsCanonicalCodes() throws {
        let quietTone = pcmTone(amplitude: 0.02, seconds: 1) + pcmSamples([Int16](repeating: 0, count: 11))
        let body = pcmSamples([33, 135, 111])
            + pcmSamples([Int16](repeating: 0, count: 11))
            + pcmTone(amplitude: 0.5, seconds: 1)
        let segments = [
            quietTone,
            quietTone,
            quietTone,
            pcmSamples([30000]),
            pcmSamples([-30000, -30000]),
            body,
        ]
        let maxCorrection = -20 * log10(0.7)
        let output = try match(
            segments,
            TTSLoudnessMatch(target: .recentMedian, maxCorrectionDB: maxCorrection, truePeakCeilingDBTP: -3),
            boundaries: [.withinSentence, .withinSentence, .withinSentence, .withinSentence, .withinSentence, .end],
            policy: TTSStitchPolicy(joinFade: .seconds(4.0 / 24000))
        )
        #expect(output.measurements[5].appliedGainDB == -maxCorrection)
        let gain = pow(10.0, output.measurements[5].appliedGainDB / 20.0)
        let emitted = intSamples(output.audio.subdata(in: output.ranges[5]))
        for (index, sample) in [33, 135, 111].enumerated() {
            let fade = PCMSeam.fadeGain(step: index, fade: 4)
            let expected = (Double(sample) / 32768 * fade * gain * 32768).rounded()
            #expect(Double(emitted[index]) == expected)
        }
        #expect(try #require(output.summary.truePeakDBTP) <= -3.0)
        #expect(emitted.dropFirst(3).contains { $0 != 0 })
    }

    @Test
    func recentProcessingHonorsTaskCancellation() async throws {
        let segments = [pcmTone(amplitude: 0.3, seconds: 10), pcmTone(amplitude: 0.2, seconds: 10)]
        let gate = ReleaseGate()
        let task = Task {
            await gate.wait()
            return try match(segments, TTSLoudnessMatch(target: .recentMedian))
        }
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
