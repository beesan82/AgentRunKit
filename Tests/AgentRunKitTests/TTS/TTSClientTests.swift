@testable import AgentRunKit
import Foundation
import Testing

private func driveForcedCompletionBarrier(
    provider: GatedTTSProvider,
    calls: [GatedTTSProvider.Call]
) async throws {
    for call in calls.prefix(3) {
        try await provider.awaitStarted(call)
    }
    await provider.release(calls[2])
    try await provider.awaitStarted(calls[3])
    await provider.release(calls[1])
    try await provider.awaitStarted(calls[4])
}

struct TTSClientTests {
    @Test
    func generateDelegatesToProvider() async throws {
        let provider = MockTTSProvider()
        let client = TTSClient(provider: provider)
        let result = try await client.generate(text: "Hello world")
        #expect(result == Data("Hello world".utf8))
    }

    @Test
    func generateWithEmptyTextThrowsEmptyText() async {
        let provider = MockTTSProvider()
        let client = TTSClient(provider: provider)
        await #expect(throws: TTSError.emptyText) {
            try await client.generate(text: "")
        }
    }

    @Test
    func generateWithWhitespaceOnlyThrowsEmptyText() async {
        let provider = MockTTSProvider()
        let client = TTSClient(provider: provider)
        await #expect(throws: TTSError.emptyText) {
            try await client.generate(text: "   \n\t  ")
        }
    }

    @Test
    func streamYieldsSegmentsInOrder() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .mp3)
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence. Third sentence."

        var segments: [TTSSegment] = []
        for try await segment in client.stream(text: text) {
            segments.append(segment)
        }

        #expect(segments.count >= 2)
        for (idx, segment) in segments.enumerated() {
            #expect(segment.index == idx)
            #expect(segment.total == segments.count)
        }
    }

    @Test
    func streamYieldsSegmentsInOrderDespiteOutOfOrderCompletion() async throws {
        let provider = ReverseDelayProvider(
            totalChunks: 4,
            config: TTSProviderConfig(maxChunkCharacters: 15, defaultVoice: "alloy", defaultFormat: .wav),
            delayPerChunk: .milliseconds(30)
        )
        let client = TTSClient(provider: provider, maxConcurrent: 4)
        let text = "First sent. Second sent. Third sent. Fourth sent."

        var indices: [Int] = []
        for try await segment in client.stream(text: text) {
            indices.append(segment.index)
        }

        #expect(indices == Array(0 ..< indices.count))
    }

    @Test
    func streamWithEmptyTextThrowsEmptyText() async {
        let provider = MockTTSProvider()
        let client = TTSClient(provider: provider)

        await #expect(throws: TTSError.emptyText) {
            for try await _ in client.stream(text: "") {}
        }
    }

    @Test
    func streamWithWhitespaceOnlyThrowsEmptyText() async {
        let provider = MockTTSProvider()
        let client = TTSClient(provider: provider)

        await #expect(throws: TTSError.emptyText) {
            for try await _ in client.stream(text: "   \n\n  ") {}
        }
    }

    @Test
    func generateAllWithEmptyTextThrowsEmptyText() async {
        let provider = MockTTSProvider()
        let client = TTSClient(provider: provider)

        await #expect(throws: TTSError.emptyText) {
            try await client.generateAll(text: "")
        }
    }

    @Test
    func generateAllConcatenatesSegments() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence."

        var segmentData: [Data] = []
        for try await segment in client.stream(text: text) {
            segmentData.append(segment.audio)
        }
        var expected = Data()
        for segment in segmentData {
            expected.append(segment)
        }

        let result = try await client.generateAll(text: text)
        #expect(result == expected)
    }

    @Test
    func generateAllSingleChunkReturnsProviderData() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 1000, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)

        let result = try await client.generateAll(text: "Short text.")
        #expect(result == Data("Short text.".utf8))
    }

    @Test
    func providerTransportErrorPropagatesAsChunkFailed() async {
        let error = TransportError.httpError(statusCode: 500, body: "Internal Server Error")
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 1000, defaultVoice: "alloy", defaultFormat: .mp3),
            responses: [0: .failure(error)]
        )
        let client = TTSClient(provider: provider)

        do {
            for try await _ in client.stream(text: "Hello.") {}
            Issue.record("Expected error")
        } catch let thrown as TTSError {
            guard case let .chunkFailed(index, total, sourceRange, transportError) = thrown else {
                Issue.record("Expected chunkFailed, got \(thrown)")
                return
            }
            #expect(index == 0)
            #expect(total == 1)
            #expect(sourceRange == 0 ..< 6)
            #expect(transportError == error)
        } catch {
            Issue.record("Expected TTSError, got \(error)")
        }
    }

    @Test
    func providerNonTransportErrorWrappedInChunkFailed() async {
        struct CustomError: Error, CustomStringConvertible {
            var description: String {
                "custom failure"
            }
        }
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 1000, defaultVoice: "alloy", defaultFormat: .mp3),
            responses: [0: .failure(CustomError())]
        )
        let client = TTSClient(provider: provider)

        do {
            for try await _ in client.stream(text: "Hello.") {}
            Issue.record("Expected error")
        } catch let error as TTSError {
            if case let .chunkFailed(index, total, sourceRange, transportError) = error {
                #expect(index == 0)
                #expect(total == 1)
                #expect(sourceRange == 0 ..< 6)
                if case let .other(message) = transportError {
                    #expect(message.contains("custom failure"))
                } else {
                    Issue.record("Expected TransportError.other, got \(transportError)")
                }
            } else {
                Issue.record("Expected chunkFailed, got \(error)")
            }
        } catch {
            Issue.record("Expected TTSError, got \(error)")
        }
    }

    @Test
    func chunkFailedReportsCorrectIndexForMidStreamFailure() async {
        let transportError = TransportError.httpError(statusCode: 500, body: "fail")
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .wav),
            responses: [1: .failure(transportError)]
        )
        let client = TTSClient(provider: provider, maxConcurrent: 1)

        do {
            for try await _ in client.stream(text: "First sentence. Second sentence. Third sentence.") {}
            Issue.record("Expected error")
        } catch let thrown as TTSError {
            guard case let .chunkFailed(index, total, sourceRange, _) = thrown else {
                Issue.record("Expected chunkFailed, got \(thrown)")
                return
            }
            #expect(index == 1)
            #expect(total >= 2)
            #expect(sourceRange.lowerBound > 0)
        } catch {
            Issue.record("Expected TTSError, got \(error)")
        }
    }

    @Test
    func boundedConcurrency() async throws {
        let innerProvider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 10, defaultVoice: "alloy", defaultFormat: .wav),
            generateDelay: .milliseconds(50)
        )
        let tracker = ConcurrencyTracker(wrapped: innerProvider)
        let client = TTSClient(provider: tracker, maxConcurrent: 2)

        let text = "One. Two. Three. Four. Five."
        for try await _ in client.stream(text: text) {}

        let peak = await tracker.getPeakConcurrent()
        #expect(peak == 2)
    }

    @Test
    func voiceDefaultsToProviderConfig() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 1000, defaultVoice: "shimmer", defaultFormat: .mp3)
        )
        let client = TTSClient(provider: provider)
        _ = try await client.generate(text: "Hello")

        let voices = await provider.getVoicesInChunkOrder()
        #expect(voices == ["shimmer"])
    }

    @Test
    func voiceOverridesProviderDefault() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 1000, defaultVoice: "alloy", defaultFormat: .mp3)
        )
        let client = TTSClient(provider: provider)
        _ = try await client.generate(text: "Hello", voice: "nova")

        let voices = await provider.getVoicesInChunkOrder()
        #expect(voices == ["nova"])
    }

    @Test
    func generateAllUsesMP3ConcatenationForMP3Format() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .mp3),
            dataFactory: wrapInMP3Metadata
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence."

        var segmentData: [Data] = []
        for try await segment in client.stream(text: text) {
            segmentData.append(segment.audio)
        }

        let mp3Concatenated = MP3Concatenator.concatenate(segmentData)
        var simpleAppend = Data()
        for data in segmentData {
            simpleAppend.append(data)
        }

        #expect(mp3Concatenated != simpleAppend)
        let result = try await client.generateAll(text: text)
        #expect(result == mp3Concatenated)
    }

    @Test
    func generateAllUsesSimpleAppendForNonMP3Format() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .wav),
            dataFactory: wrapInMP3Metadata
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence."

        var segmentData: [Data] = []
        for try await segment in client.stream(text: text) {
            segmentData.append(segment.audio)
        }

        var simpleAppend = Data()
        for data in segmentData {
            simpleAppend.append(data)
        }
        let mp3Concatenated = MP3Concatenator.concatenate(segmentData)

        #expect(simpleAppend != mp3Concatenated)
        let result = try await client.generateAll(text: text)
        #expect(result == simpleAppend)
    }

    @Test
    func formatOverrideInOptionsUsedForConcatenation() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .mp3),
            dataFactory: wrapInMP3Metadata
        )
        let client = TTSClient(provider: provider)
        let options = TTSOptions(responseFormat: .wav)
        let text = "First sentence. Second sentence."

        var segmentData: [Data] = []
        for try await segment in client.stream(text: text, options: options) {
            segmentData.append(segment.audio)
        }

        var simpleAppend = Data()
        for data in segmentData {
            simpleAppend.append(data)
        }
        let mp3Concatenated = MP3Concatenator.concatenate(segmentData)

        #expect(simpleAppend != mp3Concatenated)
        let result = try await client.generateAll(text: text, options: options)
        #expect(result == simpleAppend)
    }

    @Test
    func cancelledConsumerFollowsStandardContractWithProducerEvidence() async throws {
        let calls = (0 ..< 2).map { GatedTTSProvider.Call(voice: "alloy", index: $0) }
        let provider = GatedTTSProvider(maxChunkCharacters: 15, gatedCalls: Set(calls))
        let client = TTSClient(provider: provider, maxConcurrent: 1)
        let collector = SegmentCollector()
        let consumer = collectStream(
            client.stream(text: "First sent. Second sent.", stitch: TTSStitchPolicy()),
            into: collector
        ) {
            await provider.releaseAll()
            await provider.endRun()
        }

        try await provider.awaitStarted(calls[0])
        consumer.cancel()
        if let failure = await consumer.value {
            #expect(failure is CancellationError)
        }

        let wasCancelled = await provider.awaitCompletion(calls[0])
        #expect(wasCancelled)
        let segments = await collector.recorded()
        #expect(segments.isEmpty)
    }

    @Test
    func segmentTextAndRangeMatchChunkerOutput() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence. Third sentence."

        var segments: [TTSSegment] = []
        for try await segment in client.stream(text: text) {
            segments.append(segment)
        }

        let expected = SentenceChunker.chunk(text: text, maxCharacters: 20)
        #expect(segments.map(\.text) == expected.map(\.text))
        #expect(segments.map(\.sourceRange) == expected.map(\.sourceRange))
    }

    @Test
    func segmentSourceRangesAreLeftToRightMonotonic() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 25, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence."

        var ranges: [Range<Int>] = []
        for try await segment in client.stream(text: text) {
            ranges.append(segment.sourceRange)
        }

        let utf8 = Array(text.utf8)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == utf8.count)
        #expect(ranges.allSatisfy { !$0.isEmpty })
        for index in 1 ..< ranges.count {
            #expect(ranges[index].lowerBound >= ranges[index - 1].upperBound)
        }
    }

    @Test
    func audioMatchesTextUnderReverseCompletion() async throws {
        let provider = ReverseDelayProvider(
            totalChunks: 4,
            config: TTSProviderConfig(maxChunkCharacters: 15, defaultVoice: "alloy", defaultFormat: .wav),
            delayPerChunk: .milliseconds(20)
        )
        let client = TTSClient(provider: provider, maxConcurrent: 4)
        let text = "First sent. Second sent. Third sent. Fourth sent."

        var segments: [TTSSegment] = []
        for try await segment in client.stream(text: text) {
            segments.append(segment)
        }

        #expect(segments.count == 4)
        for segment in segments {
            #expect(Data(segment.text.utf8) == segment.audio)
        }
        #expect(segments.map(\.index) == Array(0 ..< segments.count))
    }

    @Test
    func streamWithoutPolicyPreservesRawProviderBytes() async throws {
        let provider = EncodingAwarePCMProvider(maxChunkCharacters: 20, dataFactory: alignedPCMData(for:))
        let client = TTSClient(provider: provider)

        var segments: [TTSSegment] = []
        for try await segment in client.stream(text: "First sentence. Second sentence.") {
            segments.append(segment)
        }

        #expect(segments.count >= 2)
        for segment in segments {
            #expect(segment.audio == alignedPCMData(for: segment.text))
            #expect(segment.timing == .uncomputed)
        }
    }

    @Test
    func generateAllForwardsStitchPolicyToCompletedGeneration() async throws {
        let provider = EncodingAwarePCMProvider(maxChunkCharacters: 20, dataFactory: tonePCM(for:))
        let client = TTSClient(provider: provider)
        let text = "First sentence here. Second one here. Third sentence here."
        let policies = [
            TTSStitchPolicy(targetCharacters: 15, sentencePause: .milliseconds(100)),
            TTSStitchPolicy(targetCharacters: 15, loudness: TTSLoudnessMatch(target: .recentMedian)),
        ]
        for policy in policies {
            let expected = try await client.generateWithManifest(text: text, stitch: policy)
            let audio = try await client.generateAll(text: text, stitch: policy)
            #expect(audio.elementsEqual(expected.audio))
        }
    }
}

struct TTSClientChunkPlanningTests {
    @Test
    func segmentComputedPropertiesForwardToNestedChunk() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence."

        var segments: [TTSSegment] = []
        for try await segment in client.stream(text: text) {
            segments.append(segment)
        }

        #expect(!segments.isEmpty)
        for segment in segments {
            #expect(segment.index == segment.chunk.index)
            #expect(segment.total == segment.chunk.total)
            #expect(segment.text == segment.chunk.text)
            #expect(segment.sourceRange == segment.chunk.sourceRange)
        }
    }

    @Test
    func segmentEncodingResolvesFromProviderDefaultFormat() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)

        var segments: [TTSSegment] = []
        for try await segment in client.stream(text: "First sentence. Second sentence.") {
            segments.append(segment)
        }

        #expect(!segments.isEmpty)
        for segment in segments {
            #expect(segment.encoding.format == .wav)
            #expect(segment.encoding.mimeType == "audio/wav")
            #expect(segment.encoding.fileExtension == "wav")
        }
    }

    @Test
    func segmentEncodingResolvesFromOptionsResponseFormat() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .mp3)
        )
        let client = TTSClient(provider: provider)
        let options = TTSOptions(responseFormat: .pcm)

        var segments: [TTSSegment] = []
        for try await segment in client.stream(text: "First sentence. Second sentence.", options: options) {
            segments.append(segment)
        }

        #expect(!segments.isEmpty)
        for segment in segments {
            #expect(segment.encoding.format == .pcm)
            #expect(segment.encoding.mimeType == "audio/L16")
        }
    }

    @Test(arguments: TTSAudioFormat.allCases)
    func segmentTimingDefaultsToUncomputed(format: TTSAudioFormat) async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: format)
        )
        let client = TTSClient(provider: provider)

        var segments: [TTSSegment] = []
        for try await segment in client.stream(text: "First sentence. Second sentence.") {
            segments.append(segment)
        }

        #expect(!segments.isEmpty)
        for segment in segments {
            #expect(segment.timing == .uncomputed)
            #expect(segment.timing.byteRangeInConcatenatedAudio == nil)
            #expect(segment.timing.durationSeconds == nil)
        }
    }

    @Test
    func processedStreamDeliversFirstChunkWhileLaterRequestsAreHeld() async throws {
        let calls = (0 ..< 3).map { GatedTTSProvider.Call(voice: "alloy", index: $0) }
        let provider = GatedTTSProvider(maxChunkCharacters: 15, gatedCalls: Set(calls))
        let client = TTSClient(provider: provider, maxConcurrent: 3)
        let collector = SegmentCollector()
        let consumer = collectStream(
            client.stream(
                text: "First sent. Second sent. Third sent.",
                stitch: TTSStitchPolicy(sentencePause: .milliseconds(100))
            ),
            into: collector
        ) {
            await provider.releaseAll()
            await provider.endRun()
        }

        try await provider.awaitStarted(calls[0])
        await provider.release(calls[0])
        do {
            try await collector.waitForCount(1)
        } catch {
            await provider.releaseAll()
            await provider.endRun()
            _ = await consumer.value
            throw error
        }
        let recorded = await collector.recorded()
        let first = try #require(recorded.first)
        #expect(first.index == 0)
        #expect(first.timing.byteRangeInConcatenatedAudio == 0 ..< first.audio.count)

        await provider.release(calls[1])
        await provider.release(calls[2])
        let failure = await consumer.value
        #expect(failure == nil)
        let segments = await collector.recorded()
        #expect(segments.map(\.index) == [0, 1, 2])
    }

    @Test
    func processedStreamEmitsPlainLayoutInSourceOrderAfterForcedOutOfOrderCompletion() async throws {
        let text = "One. Two. Three. Four. Five."
        let policy = TTSStitchPolicy()
        let calls = (0 ..< 5).map { GatedTTSProvider.Call(voice: "alloy", index: $0) }
        let provider = GatedTTSProvider(maxChunkCharacters: 8, gatedCalls: Set(calls))
        let client = TTSClient(provider: provider, maxConcurrent: 3)
        let plan = client.chunks(for: text, stitch: policy)
        #expect(plan.count == 5)
        let collector = SegmentCollector()
        let consumer = collectStream(client.stream(text: text, stitch: policy), into: collector) {
            await provider.releaseAll()
            await provider.endRun()
        }

        do {
            try await driveForcedCompletionBarrier(provider: provider, calls: calls)
        } catch {
            await provider.releaseAll()
            await provider.endRun()
            _ = await consumer.value
            throw error
        }
        await provider.release(calls[0])
        await provider.releaseAll()

        let failure = await consumer.value
        #expect(failure == nil)
        let segments = await collector.recorded()
        #expect(segments.map(\.index) == [0, 1, 2, 3, 4])
        var cursor = 0
        for segment in segments {
            let range = try #require(segment.timing.byteRangeInConcatenatedAudio)
            #expect(range == cursor ..< cursor + segment.audio.count)
            #expect(segment.audio == alignedPCMData(for: segment.text))
            cursor = range.upperBound
        }
    }

    @Test
    func recentStreamUnderForcedOutOfOrderCompletionMatchesCompletedRendering() async throws {
        let text = "One. Two. Three. Four. Five."
        let policy = TTSStitchPolicy(loudness: TTSLoudnessMatch(target: .recentMedian, maxCorrectionDB: 6))
        let levels = ["One": 0.15, "Two": 0.35, "Three": 0.25, "Four": 0.30, "Five": 0.20]
        let factory: @Sendable (String) -> Data = { text in
            tonePCM(amplitude: levels.first { text.hasPrefix($0.key) }?.value ?? 0.2, frames: 24000)
        }
        let calls = (0 ..< 5).map { GatedTTSProvider.Call(voice: "alloy", index: $0) }
        let provider = GatedTTSProvider(maxChunkCharacters: 8, gatedCalls: Set(calls), dataFactory: factory)
        let client = TTSClient(provider: provider, maxConcurrent: 3)
        let plan = client.chunks(for: text, stitch: policy)
        #expect(plan.count == 5)
        let completedProvider = EncodingAwarePCMProvider(maxChunkCharacters: 8, dataFactory: factory)
        let completed = try await TTSClient(provider: completedProvider).generateWithManifest(
            text: text,
            stitch: policy
        )
        let collector = SegmentCollector()
        let consumer = collectStream(client.stream(text: text, stitch: policy), into: collector) {
            await provider.releaseAll()
            await provider.endRun()
        }

        do {
            try await driveForcedCompletionBarrier(provider: provider, calls: calls)
        } catch {
            await provider.releaseAll()
            await provider.endRun()
            _ = await consumer.value
            throw error
        }
        await provider.release(calls[0])
        await provider.releaseAll()

        let failure = await consumer.value
        #expect(failure == nil)
        var concatenated = Data()
        for segment in await collector.recorded() {
            concatenated.append(segment.audio)
        }
        #expect(concatenated.elementsEqual(completed.audio))
    }

    @Test
    func chunksForMatchesStreamSegmentChunks() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 13, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence. Third sentence."

        let planned = client.chunks(for: text)
        #expect(planned.allSatisfy { $0.text.count <= 13 || $0.text.split(separator: " ").count == 1 })

        var streamed: [TTSChunk] = []
        for try await segment in client.stream(text: text) {
            streamed.append(segment.chunk)
        }

        #expect(planned == streamed)
    }

    @Test
    func chunksForReturnsEmptyArrayForEmptyInput() {
        let provider = MockTTSProvider()
        let client = TTSClient(provider: provider)
        #expect(client.chunks(for: "").isEmpty)
        #expect(client.chunks(for: "   \n\t  ").isEmpty)
    }

    @Test
    func chunksForReturnsSingleChunkForShortInput() async {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 1000, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)

        let planned = client.chunks(for: "Short.")
        #expect(planned.count == 1)
        #expect(planned.first?.index == 0)
        #expect(planned.first?.total == 1)
        #expect(planned.first?.text == "Short.")
        #expect(planned.first?.sourceRange == 0 ..< 6)

        let calls = await provider.getCallCount()
        #expect(calls == 0)
    }

    @Test
    func chunksForCanForecastWithoutInvokingProvider() async {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)
        let text = "First sentence. Second sentence. Third sentence."

        let planned = client.chunks(for: text)
        #expect(planned.count >= 2)
        #expect(planned.allSatisfy { $0.total == planned.count })
        #expect(planned.map(\.index) == Array(0 ..< planned.count))

        let calls = await provider.getCallCount()
        #expect(calls == 0)
    }

    @Test
    func chunksForShiftsRangesPastLeadingWhitespace() {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 100, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)
        let planned = client.chunks(for: "   Hello world.  ")
        #expect(planned.count == 1)
        #expect(planned.first?.text == "Hello world.")
        #expect(planned.first?.sourceRange == 3 ..< 15)
    }

    @Test
    func chunksForOversizedSentenceSplitsAtWordBoundaries() {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)
        let planned = client.chunks(for: "This is a very long sentence that exceeds the character limit.")
        #expect(planned.count >= 3)
        #expect(planned.map(\.text) == [
            "This is a very long",
            "sentence that",
            "exceeds the",
            "character limit.",
        ])
        #expect(planned.allSatisfy { $0.total == planned.count })
    }

    @Test
    func chunksForOversizedWordSplitsAtCharacterBoundaries() {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 10, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)
        let planned = client.chunks(for: "abcdefghijklmnopqrstuvwxyz")
        #expect(planned.map(\.text) == ["abcdefghij", "klmnopqrst", "uvwxyz"])
        #expect(planned.allSatisfy { $0.total == 3 })
    }

    @Test
    func chunksForPreservesUTF8RangesAcrossEmojiAndCJK() throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 100, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider)
        let text = "Great news! The price is \u{00A5}500. \u{1F600}\u{1F389}\u{1F680}"
        let planned = client.chunks(for: text)
        let utf8 = Array(text.utf8)
        for chunk in planned {
            let slice = Data(utf8[chunk.sourceRange])
            let decoded = try #require(String(bytes: slice, encoding: .utf8))
            #expect(decoded == chunk.text)
        }
        #expect(planned.last?.sourceRange.upperBound == utf8.count)
    }

    @Test
    func streamedProviderContextCarriesPerCallCoupling() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 20, defaultVoice: "alloy", defaultFormat: .wav)
        )
        let client = TTSClient(provider: provider, maxConcurrent: 1)
        let text = "First sentence. Second sentence. Third sentence."

        for try await _ in client.stream(text: text) {}

        let plan = client.chunks(for: text)
        let calls = await provider.getCalls()
        #expect(calls.count == plan.count)
        for chunk in plan {
            let call = try #require(calls[chunk.index])
            #expect(call.context.chunk == chunk)
            #expect(call.text == chunk.text)
            #expect(call.context.encoding.format == .wav)
        }
    }

    @Test
    func streamedContextCouplingHoldsUnderConcurrentCompletion() async throws {
        let inner = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 15, defaultVoice: "alloy", defaultFormat: .wav),
            generateDelay: .milliseconds(20)
        )
        let client = TTSClient(provider: inner, maxConcurrent: 4)
        let text = "First sent. Second sent. Third sent. Fourth sent."

        for try await _ in client.stream(text: text) {}

        let plan = client.chunks(for: text)
        let calls = await inner.getCalls()
        #expect(calls.count == plan.count)
        for chunk in plan {
            let call = try #require(calls[chunk.index])
            #expect(call.context.chunk == chunk)
            #expect(call.text == chunk.text)
        }
    }

    @Test
    func singleShotProviderContextHasIndexZeroTotalOneAndOriginalInputRange() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 1000, defaultVoice: "alloy", defaultFormat: .mp3)
        )
        let client = TTSClient(provider: provider)
        _ = try await client.generate(text: "  Hello world.  ")

        let calls = await provider.getCalls()
        #expect(calls.count == 1)
        let call = try #require(calls[0])
        #expect(call.context.chunk.index == 0)
        #expect(call.context.chunk.total == 1)
        #expect(call.context.chunk.text == "Hello world.")
        #expect(call.context.chunk.sourceRange == 2 ..< 14)
        #expect(call.text == "Hello world.")
        #expect(call.context.encoding.format == .mp3)
    }

    @Test
    func singleShotProviderContextHonorsOptionsResponseFormat() async throws {
        let provider = MockTTSProvider(
            config: TTSProviderConfig(maxChunkCharacters: 1000, defaultVoice: "alloy", defaultFormat: .mp3)
        )
        let client = TTSClient(provider: provider)
        _ = try await client.generate(text: "Hi", options: TTSOptions(responseFormat: .opus))

        let calls = await provider.getCalls()
        let call = try #require(calls[0])
        #expect(call.context.encoding.format == .opus)
        #expect(call.context.encoding.mimeType == "audio/opus")
    }

    @Test
    func chunksForHonorsPolicyPlanningFieldsWithoutProviderCalls() async {
        let provider = EncodingAwarePCMProvider(maxChunkCharacters: 200, dataFactory: alignedPCMData(for:))
        let client = TTSClient(provider: provider)
        let text = "Aaa one. Bbb two. Ccc three.\n\nDdd four. Eee five. Fff six."
        let greedy = client.chunks(for: text)
        let targeted = client.chunks(for: text, stitch: TTSStitchPolicy(targetCharacters: 20))
        let paragraph = client.chunks(
            for: text,
            stitch: TTSStitchPolicy(targetCharacters: 20, preferParagraphBoundaries: true)
        )

        #expect(greedy.count == 1)
        #expect(targeted.count > greedy.count)
        #expect(paragraph != targeted)
        #expect(paragraph.contains { $0.trailingBoundary == .paragraph })
        #expect(targeted.map(\.text).joined() == greedy.map(\.text).joined())
        #expect(paragraph.map(\.text).joined() == greedy.map(\.text).joined())
        let calls = await provider.generateCallCount
        #expect(calls == 0)
    }

    @Test
    func chunksForPreviewMatchesStreamBatchAndManifestPlanning() async throws {
        let provider = EncodingAwarePCMProvider(maxChunkCharacters: 200, dataFactory: alignedPCMData(for:))
        let client = TTSClient(provider: provider)
        let text = "Aaa one. Bbb two. Ccc three.\n\nDdd four. Eee five. Fff six."
        let policies = [
            TTSStitchPolicy(targetCharacters: 20),
            TTSStitchPolicy(targetCharacters: 20, preferParagraphBoundaries: true),
        ]
        for policy in policies {
            let preview = client.chunks(for: text, stitch: policy)
            var streamed: [TTSChunk] = []
            for try await segment in client.stream(text: text, stitch: policy) {
                streamed.append(segment.chunk)
            }
            let batch = try await client.generateBatch(text: text, stitch: policy)
            let manifest = try await client.generateWithManifest(text: text, stitch: policy)
            let audio = try await client.generateAll(text: text, stitch: policy)

            #expect(preview == streamed)
            #expect(preview == batch.completedSegments.map(\.chunk))
            #expect(preview == manifest.manifest.map(\.chunk))
            #expect(audio == manifest.audio)
        }
    }
}

extension TTSClientTests {
    @Test
    func processingFailureTerminatesWaitersWithOtherRequestsHeld() async throws {
        let calls = (0 ..< 3).map { GatedTTSProvider.Call(voice: "alloy", index: $0) }
        let provider = GatedTTSProvider(
            maxChunkCharacters: 15,
            gatedCalls: Set(calls),
            responses: [0: .success(Data())]
        )
        let client = TTSClient(provider: provider, maxConcurrent: 3)
        let collector = SegmentCollector()
        let consumer = collectStream(
            client.stream(text: "First sent. Second sent. Third sent.", stitch: TTSStitchPolicy()),
            into: collector
        ) {
            await provider.releaseAll()
            await provider.endRun()
        }

        do {
            for call in calls {
                try await provider.awaitStarted(call)
            }
            await provider.release(calls[0])
            await #expect(throws: TTSError.self) {
                try await collector.waitForCount(1)
            }
        } catch {
            await provider.releaseAll()
            await provider.endRun()
            _ = await consumer.value
            throw error
        }

        let failure = await consumer.value
        let error = try #require(failure as? TTSError)
        guard case .invalidConfiguration = error else {
            Issue.record("expected invalidConfiguration, got \(error)")
            return
        }
        #expect(await collector.recorded().isEmpty)
        #expect(await provider.awaitCompletion(calls[1]))
        #expect(await provider.awaitCompletion(calls[2]))
    }
}
