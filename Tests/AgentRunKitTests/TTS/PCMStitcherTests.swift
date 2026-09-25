@testable import AgentRunKit
import Foundation
import Testing

private let stitchFormat: PCMFormat = {
    guard let format = PCMFormat(TTSAudioEncoding(.pcm, sampleRate: 24000, channels: 1, bitsPerSample: 16)) else {
        preconditionFailure("test fixture encoding must be valid 16-bit PCM")
    }
    return format
}()

private let stereoFormat: PCMFormat = {
    guard let format = PCMFormat(TTSAudioEncoding(.pcm, sampleRate: 24000, channels: 2, bitsPerSample: 16)) else {
        preconditionFailure("test fixture encoding must be valid 16-bit PCM")
    }
    return format
}()

private func pcmFrames(_ count: Int, sample: Int16) -> Data {
    var data = Data(capacity: count * 2)
    let bits = UInt16(bitPattern: sample)
    for _ in 0 ..< count {
        data.append(UInt8(bits & 0x00FF))
        data.append(UInt8(bits >> 8))
    }
    return data
}

private func stereoFrames(_ count: Int, left: Int16, right: Int16) -> Data {
    var data = Data(capacity: count * 4)
    let leftBits = UInt16(bitPattern: left)
    let rightBits = UInt16(bitPattern: right)
    for _ in 0 ..< count {
        data.append(UInt8(leftBits & 0x00FF))
        data.append(UInt8(leftBits >> 8))
        data.append(UInt8(rightBits & 0x00FF))
        data.append(UInt8(rightBits >> 8))
    }
    return data
}

private func sample(_ data: Data, frame: Int) -> Int16 {
    let index = data.startIndex + frame * 2
    return Int16(bitPattern: UInt16(data[index]) | (UInt16(data[index + 1]) << 8))
}

private func stereoSample(_ data: Data, frame: Int) -> (Int16, Int16) {
    let index = data.startIndex + frame * 4
    let left = Int16(bitPattern: UInt16(data[index]) | (UInt16(data[index + 1]) << 8))
    let right = Int16(bitPattern: UInt16(data[index + 2]) | (UInt16(data[index + 3]) << 8))
    return (left, right)
}

private func smoothstep(step: Int, fade: Int) -> Double {
    guard fade > 1 else { return 0 }
    let position = Double(step) / Double(fade - 1)
    return position * position * (3 - 2 * position)
}

private func stitch(
    _ segments: [Data],
    _ boundaries: [TTSBoundary],
    _ policy: TTSStitchPolicy,
    format: PCMFormat? = nil
) throws -> (audio: Data, ranges: [Range<Int>]) {
    try PCMStitcher.stitch(segments: segments, boundaries: boundaries, policy: policy, format: format ?? stitchFormat)
}

struct PCMStitcherTests {
    @Test
    func sentenceAndParagraphSeamsInsertSilenceOfExpectedSize() throws {
        let segments = [pcmFrames(100, sample: 5000), pcmFrames(100, sample: 5000), pcmFrames(100, sample: 5000)]
        let boundaries: [TTSBoundary] = [.sentence, .paragraph, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(100), paragraphPause: .milliseconds(500))
        let result = try stitch(segments, boundaries, policy)

        let sentenceBytes = 4800
        let paragraphBytes = 24000
        #expect(result.ranges == [
            0 ..< 200,
            (200 + sentenceBytes) ..< (400 + sentenceBytes),
            (400 + sentenceBytes + paragraphBytes) ..< (600 + sentenceBytes + paragraphBytes),
        ])
        #expect(result.audio.count == 600 + sentenceBytes + paragraphBytes)

        let firstGap = result.audio.subdata(in: result.ranges[0].upperBound ..< result.ranges[1].lowerBound)
        #expect(firstGap.count == sentenceBytes)
        #expect(firstGap.allSatisfy { $0 == 0 })
        let secondGap = result.audio.subdata(in: result.ranges[1].upperBound ..< result.ranges[2].lowerBound)
        #expect(secondGap.count == paragraphBytes)
        #expect(secondGap.allSatisfy { $0 == 0 })
    }

    @Test
    func withinSentenceAndEndSeamsInsertNoSilence() throws {
        let segments = [pcmFrames(50, sample: 3000), pcmFrames(50, sample: 3000), pcmFrames(50, sample: 3000)]
        let boundaries: [TTSBoundary] = [.withinSentence, .sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(100), paragraphPause: .milliseconds(500))
        let result = try stitch(segments, boundaries, policy)

        #expect(result.ranges[0] == 0 ..< 100)
        #expect(result.ranges[1] == 100 ..< 200)
        #expect(result.ranges[2].lowerBound == 200 + 4800)
        #expect(result.audio.count == 300 + 4800)
    }

    @Test
    func zeroPausesReproduceRawConcatenation() throws {
        let segments = [pcmFrames(40, sample: 1234), pcmFrames(40, sample: -2345)]
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let result = try stitch(segments, boundaries, TTSStitchPolicy())
        var raw = Data()
        for segment in segments {
            raw.append(segment)
        }
        #expect(result.audio == raw)
        #expect(result.ranges == [0 ..< 80, 80 ..< 160])
    }

    @Test
    func identicalInputsProduceIdenticalBytes() throws {
        let segments = [pcmFrames(300, sample: 8000), pcmFrames(300, sample: 8000)]
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(80), joinFade: .milliseconds(5))
        let first = try stitch(segments, boundaries, policy)
        let second = try stitch(segments, boundaries, policy)
        #expect(first.audio == second.audio)
        #expect(first.ranges == second.ranges)
    }

    @Test
    func joinFadeAttenuatesEdgesBesidePositivePauses() throws {
        let level: Int16 = 10000
        let segments = [pcmFrames(1000, sample: level), pcmFrames(1000, sample: level)]
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(50), joinFade: .milliseconds(5))
        let result = try stitch(segments, boundaries, policy)

        let seg0 = result.audio.subdata(in: result.ranges[0])
        let seg1 = result.audio.subdata(in: result.ranges[1])

        #expect(sample(seg0, frame: 0) == level)
        #expect(sample(seg0, frame: 500) == level)
        #expect(sample(seg0, frame: 999) < level)
        #expect(sample(seg0, frame: 999) >= 0)

        #expect(sample(seg1, frame: 0) < level)
        #expect(sample(seg1, frame: 0) >= 0)
        #expect(sample(seg1, frame: 999) == level)
    }

    @Test
    func fadeFollowsSmoothstepCurveOnBipolarSignal() throws {
        let level: Int16 = -10000
        let segments = [pcmFrames(1000, sample: level), pcmFrames(1000, sample: level)]
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(50), joinFade: .milliseconds(5))
        let result = try stitch(segments, boundaries, policy)

        let seg0 = result.audio.subdata(in: result.ranges[0])
        let fade = 120
        for offset in [0, 59, 119] {
            let expected = Int16((Double(level) * smoothstep(step: offset, fade: fade)).rounded())
            #expect(sample(seg0, frame: 999 - offset) == expected)
        }
        #expect(sample(seg0, frame: 400) == level)
    }

    @Test
    func fadeEndpointsAreExactZeroAndOne() throws {
        let level: Int16 = 10000
        let segments = [pcmFrames(1000, sample: level), pcmFrames(1000, sample: level)]
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(50), joinFade: .milliseconds(5))
        let result = try stitch(segments, boundaries, policy)

        let seg0 = result.audio.subdata(in: result.ranges[0])
        let seg1 = result.audio.subdata(in: result.ranges[1])
        #expect(sample(seg0, frame: 999) == 0)
        #expect(sample(seg0, frame: 999 - 119) == level)
        #expect(sample(seg1, frame: 0) == 0)
        #expect(sample(seg1, frame: 119) == level)
    }

    @Test
    func directJoinGetsCappedFadeWhileOuterEdgesStayUntouched() throws {
        let positive: Int16 = 10000
        let negative: Int16 = -10000
        let segments = [
            pcmFrames(500, sample: positive), pcmFrames(500, sample: negative), pcmFrames(500, sample: positive),
        ]
        let boundaries: [TTSBoundary] = [.withinSentence, .sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(50), joinFade: .milliseconds(5))
        let result = try stitch(segments, boundaries, policy)

        let seg0 = result.audio.subdata(in: result.ranges[0])
        let seg1 = result.audio.subdata(in: result.ranges[1])
        let seg2 = result.audio.subdata(in: result.ranges[2])

        #expect(sample(seg0, frame: 0) == positive)
        #expect(sample(seg0, frame: 476) == positive)
        #expect(sample(seg0, frame: 499) == 0)

        #expect(sample(seg1, frame: 0) == 0)
        #expect(sample(seg1, frame: 23) == negative)
        #expect(sample(seg1, frame: 380) == negative)
        #expect(sample(seg1, frame: 499) == 0)

        #expect(sample(seg2, frame: 119) == positive)
        #expect(sample(seg2, frame: 499) == positive)

        let unfadedJump = abs(Int(positive) - Int(negative))
        let fadedJump = abs(Int(sample(seg0, frame: 499)) - Int(sample(seg1, frame: 0)))
        #expect(fadedJump < unfadedJump)

        #expect(result.ranges[1].lowerBound == result.ranges[0].upperBound)
        #expect(result.ranges[2].lowerBound - result.ranges[1].upperBound == 2400)
    }

    @Test
    func existingQuietReducesInsertedSilenceWithoutDeletingSource() throws {
        let first = pcmFrames(100, sample: 5000) + pcmFrames(2400, sample: 0)
        let second = pcmFrames(1200, sample: 0) + pcmFrames(100, sample: 5000)
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(200))
        let result = try stitch([first, second], boundaries, policy)

        #expect(result.ranges[1].lowerBound - result.ranges[0].upperBound == 2400)
        #expect(result.audio.subdata(in: result.ranges[0]) == first)
        #expect(result.audio.subdata(in: result.ranges[1]) == second)
        let gap = result.audio.subdata(in: result.ranges[0].upperBound ..< result.ranges[1].lowerBound)
        #expect(gap.allSatisfy { $0 == 0 })
        #expect(result.audio.count == first.count + 2400 + second.count)
    }

    @Test
    func longerExistingQuietInsertsNoSilence() throws {
        let first = pcmFrames(100, sample: 5000) + pcmFrames(5400, sample: 0)
        let second = pcmFrames(100, sample: 5000)
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(200))
        let result = try stitch([first, second], boundaries, policy)

        #expect(result.ranges[1].lowerBound == result.ranges[0].upperBound)
        #expect(result.audio.subdata(in: result.ranges[0]) == first)
        #expect(result.audio.subdata(in: result.ranges[1]) == second)
        #expect(result.audio.count == first.count + second.count)
    }

    @Test
    func alreadyQuietEdgesSkipFadesAndKeepEverySourceFrame() throws {
        let first = pcmFrames(499, sample: 8000) + pcmFrames(1, sample: 0)
        let second = pcmFrames(60, sample: 0) + pcmFrames(440, sample: 8000)
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(50), joinFade: .milliseconds(5))
        let result = try stitch([first, second], boundaries, policy)

        #expect(result.audio.subdata(in: result.ranges[0]) == first)
        #expect(result.audio.subdata(in: result.ranges[1]) == second)
        #expect(result.ranges[1].lowerBound - result.ranges[0].upperBound == 2280)
    }

    @Test
    func isolatedZeroCrossingDoesNotCountAsPause() throws {
        let first = pcmFrames(500, sample: 5000)
        let second = pcmFrames(1, sample: 0) + pcmFrames(499, sample: 5000)
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(50), joinFade: .milliseconds(5))
        let result = try stitch([first, second], boundaries, policy)

        #expect(result.ranges[1].lowerBound - result.ranges[0].upperBound == 2400)
        #expect(result.audio.subdata(in: result.ranges[1]) == second)
    }

    @Test
    func stereoQuietRequiresEveryChannel() throws {
        let first = stereoFrames(500, left: 5000, right: 5000)
        let second = stereoFrames(60, left: 0, right: 5000) + stereoFrames(440, left: 5000, right: 5000)
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(50), joinFade: .milliseconds(5))
        let result = try stitch([first, second], boundaries, policy, format: stereoFormat)

        #expect(result.ranges[1].lowerBound - result.ranges[0].upperBound == 4800)
        let body = result.audio.subdata(in: result.ranges[1])
        #expect(stereoSample(body, frame: 0).1 < 5000)
        #expect(stereoSample(body, frame: 0).1 >= 0)
        #expect(stereoSample(body, frame: 119).1 == 5000)
    }

    @Test
    func shortChunksKeepOneFrameUntouched() throws {
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(50), joinFade: .milliseconds(5))

        let single = try stitch([pcmFrames(1, sample: 9000), pcmFrames(1, sample: 9000)], boundaries, policy)
        #expect(single.audio.subdata(in: single.ranges[0]) == pcmFrames(1, sample: 9000))
        #expect(single.audio.subdata(in: single.ranges[1]) == pcmFrames(1, sample: 9000))
        #expect(single.ranges[1].lowerBound - single.ranges[0].upperBound == 2400)

        let pair = try stitch([pcmFrames(2, sample: 9000), pcmFrames(2, sample: 9000)], boundaries, policy)
        let head = pair.audio.subdata(in: pair.ranges[0])
        let tail = pair.audio.subdata(in: pair.ranges[1])
        #expect(sample(head, frame: 0) == 9000)
        #expect(sample(head, frame: 1) == 0)
        #expect(sample(tail, frame: 0) == 0)
        #expect(sample(tail, frame: 1) == 9000)
    }

    @Test
    func subTwoMillisecondBudgetStillCreditsExistingQuiet() throws {
        let first = pcmFrames(100, sample: 5000) + pcmFrames(48, sample: 0)
        let second = pcmFrames(48, sample: 0) + pcmFrames(100, sample: 5000)
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .milliseconds(1))
        let result = try stitch([first, second], boundaries, policy)

        #expect(result.ranges[1].lowerBound == result.ranges[0].upperBound)
        #expect(result.audio.subdata(in: result.ranges[0]) == first)
        #expect(result.audio.subdata(in: result.ranges[1]) == second)
    }

    @Test
    func emptyOrMisalignedSegmentsThrow() {
        let boundaries: [TTSBoundary] = [.sentence, .end]
        #expect(throws: TTSError.self) {
            try stitch([Data(), pcmFrames(10, sample: 100)], boundaries, TTSStitchPolicy())
        }
        #expect(throws: TTSError.self) {
            try stitch([Data([0x01, 0x02, 0x03])], [.end], TTSStitchPolicy())
        }
    }

    @Test
    func overflowingPauseThrows() {
        let segments = [pcmFrames(10, sample: 1000), pcmFrames(10, sample: 1000)]
        let boundaries: [TTSBoundary] = [.sentence, .end]
        let policy = TTSStitchPolicy(sentencePause: .seconds(1_000_000_000_000_000))
        #expect(throws: TTSError.self) {
            try stitch(segments, boundaries, policy)
        }
    }
}
