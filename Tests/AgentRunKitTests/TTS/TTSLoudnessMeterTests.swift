@testable import AgentRunKit
import Foundation
import Testing

private let sampleRate = 24000

private let dcEdgeOvershootDBTP = -9.432917636236164
private let phaseShiftedPeakDBTP = 0.09567262593868676
private let stepOnsetPeakDBTP = 1.025942511723991
private let fullBlockTrailingPeakDBTP = 0.10950745815708413

private func tone(freq: Double, amplitude: Double, seconds: Double) -> [Double] {
    tone(freq: freq, amplitude: amplitude, seconds: seconds, sampleRate: sampleRate)
}

private func tone(freq: Double, amplitude: Double, seconds: Double, sampleRate: Int) -> [Double] {
    let count = Int(seconds * Double(sampleRate))
    return (0 ..< count).map { amplitude * sin(2 * .pi * freq * Double($0) / Double(sampleRate)) }
}

private func loudness(_ samples: [Double]) throws -> Double {
    try loudness(samples, sampleRate: sampleRate)
}

private func loudness(_ samples: [Double], sampleRate: Int) throws -> Double {
    try #require(TTSLoudnessMeter.integratedLoudness(samples, sampleRate: sampleRate).lufs)
}

private func loudnessByBlocks(_ samples: [Double], sizes: [Int], sampleRate: Int) -> TTSLoudnessReading {
    let state = TTSLoudnessMeter.IntegratedState(sampleRate: sampleRate)
    var offset = 0
    for size in sizes {
        let end = min(offset + size, samples.count)
        samples[offset ..< end].withUnsafeBufferPointer { state.append($0) }
        offset = end
    }
    if offset < samples.count {
        samples[offset...].withUnsafeBufferPointer { state.append($0) }
    }
    return state.reading()
}

private func peakByBlocks(_ samples: [Double], sizes: [Int]) -> Double {
    var state = TTSLoudnessMeter.TruePeakState()
    var offset = 0
    for size in sizes {
        let end = min(offset + size, samples.count)
        samples[offset ..< end].withUnsafeBufferPointer { state.append($0) }
        offset = end
    }
    if offset < samples.count {
        samples[offset...].withUnsafeBufferPointer { state.append($0) }
    }
    return state.readingDBTP()
}

struct TTSLoudnessMeterTests {
    @Test
    func sineMatchesFFmpegValidatedLoudness() throws {
        let lufs = try loudness(tone(freq: 1000, amplitude: 0.5, seconds: 8))
        #expect(abs(lufs - -9.0) < 0.2)
    }

    @Test
    func uniformScalingShiftsLoudnessByExactlyTheDecibels() throws {
        let base = tone(freq: 1000, amplitude: 0.5, seconds: 8)
        let loud = try loudness(base)
        let quiet = try loudness(base.map { $0 * 0.5 })
        #expect(abs((loud - quiet) - 6.0206) < 0.05)
    }

    @Test
    func appendedSilenceIsGatedOutAndDoesNotChangeLoudness() throws {
        let speech = tone(freq: 1000, amplitude: 0.5, seconds: 4)
        let bare = try loudness(speech)
        let withSilence = try loudness(speech + [Double](repeating: 0, count: sampleRate * 4))
        #expect(abs(bare - withSilence) < 0.3)
    }

    @Test
    func bufferShorterThanAGatingBlockIsUnmeasurable() {
        let short = tone(freq: 1000, amplitude: 0.5, seconds: 0.2)
        let reading = TTSLoudnessMeter.integratedLoudness(short, sampleRate: sampleRate)
        #expect(reading == .unmeasurable(.shorterThanGatingBlock))
    }

    @Test
    func silenceIsUnmeasurableBelowTheAbsoluteGate() {
        let silence = [Double](repeating: 0, count: sampleRate * 2)
        let reading = TTSLoudnessMeter.integratedLoudness(silence, sampleRate: sampleRate)
        #expect(reading == .unmeasurable(.belowAbsoluteGate))
    }

    @Test
    func relativeGateExcludesQuietBlocksWellAboveTheAbsoluteGate() throws {
        let loud = tone(freq: 1000, amplitude: 0.5, seconds: 4)
        let quiet = tone(freq: 1000, amplitude: 0.05, seconds: 4)
        let loudOnly = try loudness(loud)
        let mixed = try loudness(loud + quiet)
        #expect(abs(mixed - loudOnly) < 1.0)
    }

    @Test
    func truePeakRecoversInterSamplePeakAboveSamplePeak() throws {
        let offPhase = (0 ..< sampleRate * 2).map { sin(2 * .pi * 6000 * Double($0) / Double(sampleRate) + .pi / 4) }
        let samplePeak = try 20 * log10(#require(offPhase.map(abs).max()))
        let truePeak = TTSLoudnessMeter.truePeakDBTP(offPhase)
        #expect(samplePeak < -2.5)
        #expect(truePeak > samplePeak + 2.0)
        #expect(truePeak > -0.5)
    }

    @Test
    func truePeakOfALowLevelToneStaysNearItsSamplePeak() throws {
        let quiet = tone(freq: 1000, amplitude: 0.25, seconds: 1)
        let samplePeak = try 20 * log10(#require(quiet.map(abs).max()))
        let truePeak = TTSLoudnessMeter.truePeakDBTP(quiet)
        #expect(abs(truePeak - samplePeak) < 0.5)
    }

    @Test
    func truePeakOfSilenceIsNegativeInfinity() {
        #expect(TTSLoudnessMeter.truePeakDBTP([Double](repeating: 0, count: 100)) == -.infinity)
    }

    @Test
    func loudnessMatchesOneShotAcrossIrregularBlockPartitions() throws {
        let signal = tone(freq: 1000, amplitude: 0.5, seconds: 4)
        let expected = try loudness(signal)
        let partitioned = try #require(
            loudnessByBlocks(signal, sizes: [1, 7, 100, 2399, 2400, 2401, 4096, 3, 0, 7777], sampleRate: sampleRate)
                .lufs
        )
        #expect(abs(partitioned - expected) < 1e-6)
    }

    @Test
    func loudnessMatchesOneShotForSingleSampleBlocks() throws {
        let signal = tone(freq: 1000, amplitude: 0.5, seconds: 4)
        let expected = try loudness(signal)
        let partitioned = try #require(
            loudnessByBlocks(signal, sizes: Array(repeating: 1, count: signal.count), sampleRate: sampleRate).lufs
        )
        #expect(abs(partitioned - expected) < 1e-6)
    }

    @Test
    func largeSingleAppendMatchesBlockBoundaryPartitions() throws {
        let signal = tone(freq: 1000, amplitude: 0.5, seconds: 8)
        let single = TTSLoudnessMeter.IntegratedState(sampleRate: sampleRate)
        signal.withUnsafeBufferPointer { single.append($0) }
        let expected = try #require(single.reading().lufs)
        let blockAligned = try #require(
            loudnessByBlocks(signal, sizes: Array(repeating: 4096, count: 50), sampleRate: sampleRate).lufs
        )
        let boundaryCrossing = try #require(
            loudnessByBlocks(signal, sizes: [4095, 4096, 4097, 1, 8191, 8193], sampleRate: sampleRate).lufs
        )
        #expect(abs(blockAligned - expected) < 1e-6)
        #expect(abs(boundaryCrossing - expected) < 1e-6)
    }

    @Test(arguments: [16000, 24000, 44100, 48000])
    func loudnessPartitionEquivalenceHoldsAcrossRepresentativeSampleRates(rate: Int) throws {
        let signal = tone(freq: 1000, amplitude: 0.5, seconds: 4, sampleRate: rate)
        let expected = try loudness(signal, sampleRate: rate)
        let sizes = [7, rate / 10 - 1, rate / 10, 4096, 1]
        let partitioned = try #require(loudnessByBlocks(signal, sizes: sizes, sampleRate: rate).lufs)
        #expect(abs(partitioned - expected) < 1e-6)
    }

    @Test
    func unmeasurableReasonsSurvivePartitioning() {
        let short = tone(freq: 1000, amplitude: 0.5, seconds: 0.2)
        #expect(
            loudnessByBlocks(short, sizes: [100, 1, 4699], sampleRate: sampleRate)
                == TTSLoudnessMeter.integratedLoudness(short, sampleRate: sampleRate)
        )
        let silence = [Double](repeating: 0, count: sampleRate * 2)
        #expect(
            loudnessByBlocks(silence, sizes: [1, 4096, 1000], sampleRate: sampleRate)
                == TTSLoudnessMeter.integratedLoudness(silence, sampleRate: sampleRate)
        )
        #expect(peakByBlocks(silence, sizes: [1, 4096, 1000]) == -.infinity)
    }

    @Test
    func prefixLoudnessReadingStaysValidWhenMoreSamplesArrive() throws {
        let signal = tone(freq: 1000, amplitude: 0.4, seconds: 2)
        let prefix = Array(signal.prefix(signal.count / 2))
        let rest = Array(signal.suffix(signal.count - signal.count / 2))
        let state = TTSLoudnessMeter.IntegratedState(sampleRate: sampleRate)
        prefix.withUnsafeBufferPointer { state.append($0) }
        let prefixReading = try #require(state.reading().lufs)
        #expect(try abs(prefixReading - loudness(prefix)) < 1e-6)
        rest.withUnsafeBufferPointer { state.append($0) }
        let continued = try #require(state.reading().lufs)
        #expect(try abs(continued - loudness(signal)) < 1e-6)
    }

    @Test
    func truePeakMatchesOneShotAcrossFilterCrossings() {
        var signal = tone(freq: 1000, amplitude: 0.4, seconds: 2)
        signal[signal.count - 1] = 0.9
        let expected = TTSLoudnessMeter.truePeakDBTP(signal)
        #expect(expected.isFinite)
        let partitioned = peakByBlocks(signal, sizes: [1, 4799, 11, 12, 13, 4096, 1, 9999])
        #expect(abs(partitioned - expected) < 1e-8)
    }

    @Test
    func truePeakMatchesOneShotForSingleSampleBlocks() {
        var signal = tone(freq: 1000, amplitude: 0.4, seconds: 2)
        signal[signal.count - 1] = 0.9
        let expected = TTSLoudnessMeter.truePeakDBTP(signal)
        let partitioned = peakByBlocks(signal, sizes: Array(repeating: 1, count: signal.count))
        #expect(abs(partitioned - expected) < 1e-8)
    }

    @Test
    func endImpulsePeakEqualsItsSamplePeak() {
        var signal = [Double](repeating: 0, count: sampleRate)
        signal[signal.count - 1] = 0.9
        let samplePeak = 20 * log10(0.9)
        #expect(abs(TTSLoudnessMeter.truePeakDBTP(signal) - samplePeak) < 1e-9)
        #expect(abs(peakByBlocks(signal, sizes: [sampleRate - 1, 1]) - samplePeak) < 1e-9)
    }

    @Test
    func dcPeakReproducesEdgeOvershootAcrossPartitions() {
        // Pinned peak values below reproduce the c5bce5d scalar interpolator as regression
        // anchors, not certified reconstruction truth: 1e-6 covers baseline summation-order
        // differences, while 1e-8 and 1e-9 assert cross-partition equivalence and analytic properties.
        let signal = [Double](repeating: 0.3, count: sampleRate)
        let expected = TTSLoudnessMeter.truePeakDBTP(signal)
        #expect(abs(expected - dcEdgeOvershootDBTP) < 1e-6)
        #expect(abs(peakByBlocks(signal, sizes: [7777, 1, 16222]) - expected) < 1e-8)
    }

    @Test
    func prefixPeakReadingStaysValidWhenMoreSamplesArrive() {
        var signal = tone(freq: 1000, amplitude: 0.4, seconds: 2)
        signal[signal.count - 1] = 0.9
        let prefix = Array(signal.prefix(signal.count / 2))
        let rest = Array(signal.suffix(signal.count - signal.count / 2))
        var state = TTSLoudnessMeter.TruePeakState()
        prefix.withUnsafeBufferPointer { state.append($0) }
        #expect(abs(state.readingDBTP() - TTSLoudnessMeter.truePeakDBTP(prefix)) < 1e-8)
        rest.withUnsafeBufferPointer { state.append($0) }
        #expect(abs(state.readingDBTP() - TTSLoudnessMeter.truePeakDBTP(signal)) < 1e-8)
    }

    @Test
    func phaseShiftedPeakSurvivesPartitioning() {
        let offPhase: [Double] = (0 ..< sampleRate * 2).map { index in
            sin(2 * .pi * 6000 * Double(index) / Double(sampleRate) + .pi / 4)
        }
        let expected = TTSLoudnessMeter.truePeakDBTP(offPhase)
        #expect(abs(expected - phaseShiftedPeakDBTP) < 1e-6)
        #expect(abs(peakByBlocks(offPhase, sizes: [3, 5000, 1, 42996]) - expected) < 1e-8)
    }

    @Test
    func stepOvershootSurvivesASplitAtTheStep() {
        let signal = [0.9, 0.9] + [Double](repeating: 0, count: 200)
        let expected = TTSLoudnessMeter.truePeakDBTP(signal)
        #expect(abs(expected - stepOnsetPeakDBTP) < 1e-6)
        #expect(abs(peakByBlocks(signal, sizes: [1, 201]) - expected) < 1e-8)
    }

    @Test
    func tailDominantPeakFallsAsRealSamplesReplaceVirtualTail() {
        let prefix = [0.9, 0.9]
        let samplePeak = 20 * log10(0.9)
        var state = TTSLoudnessMeter.TruePeakState()
        prefix.withUnsafeBufferPointer { state.append($0) }
        let first = state.readingDBTP()
        #expect(abs(first - stepOnsetPeakDBTP) < 1e-6)
        #expect(first > samplePeak)
        #expect(state.readingDBTP() == first)
        let rest = [Double](repeating: 0.9, count: 98)
        rest.withUnsafeBufferPointer { state.append($0) }
        let full = state.readingDBTP()
        #expect(abs(full - fullBlockTrailingPeakDBTP) < 1e-6)
        #expect(full < first)
        #expect(abs(full - TTSLoudnessMeter.truePeakDBTP(prefix + rest)) < 1e-8)
    }

    @Test
    func truePeakCopiesMeasureIndependently() {
        let prefix = [0.9, 0.9]
        var first = TTSLoudnessMeter.TruePeakState()
        prefix.withUnsafeBufferPointer { first.append($0) }
        var second = first
        let rest = [Double](repeating: 0.9, count: 98)
        rest.withUnsafeBufferPointer { second.append($0) }
        #expect(abs(first.readingDBTP() - stepOnsetPeakDBTP) < 1e-6)
        #expect(abs(second.readingDBTP() - fullBlockTrailingPeakDBTP) < 1e-6)
        #expect(abs(first.readingDBTP() - stepOnsetPeakDBTP) < 1e-6)
    }

    @Test
    func largeSinglePeakAppendMatchesBlockBoundaryPartitions() {
        var signal = tone(freq: 1000, amplitude: 0.4, seconds: 2)
        signal[signal.count - 1] = 0.9
        var single = TTSLoudnessMeter.TruePeakState()
        signal.withUnsafeBufferPointer { single.append($0) }
        let expected = single.readingDBTP()
        #expect(abs(peakByBlocks(signal, sizes: Array(repeating: 4096, count: 20)) - expected) < 1e-8)
        #expect(abs(peakByBlocks(signal, sizes: [4095, 4096, 4097, 1, 8191]) - expected) < 1e-8)
    }
}
