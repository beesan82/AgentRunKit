@testable import AgentRunKit
import Foundation

struct MockProviderCall: Equatable {
    let text: String
    let voice: String
    let options: TTSOptions
    let context: TTSChunkContext
}

actor MockTTSProvider: TTSProvider {
    let config: TTSProviderConfig
    private var totalCallCount = 0
    private var responses: [Int: Result<Data, any Error>]
    private var callsByChunk: [Int: MockProviderCall] = [:]
    private var generateDelay: Duration?
    private let dataFactory: @Sendable (String) -> Data

    init(
        config: TTSProviderConfig = TTSProviderConfig(
            maxChunkCharacters: 50,
            defaultVoice: "alloy",
            defaultFormat: .mp3
        ),
        responses: [Int: Result<Data, any Error>] = [:],
        generateDelay: Duration? = nil,
        dataFactory: @Sendable @escaping (String) -> Data = { Data($0.utf8) }
    ) {
        self.config = config
        self.responses = responses
        self.generateDelay = generateDelay
        self.dataFactory = dataFactory
    }

    func generate(
        text: String,
        voice: String,
        options: TTSOptions,
        context: TTSChunkContext
    ) async throws -> Data {
        totalCallCount += 1
        let chunkIndex = context.chunk.index
        callsByChunk[chunkIndex] = MockProviderCall(
            text: text,
            voice: voice,
            options: options,
            context: context
        )

        if let delay = generateDelay {
            try await Task.sleep(for: delay)
        }

        if let result = responses[chunkIndex] {
            return try result.get()
        }
        return dataFactory(text)
    }

    func getCallCount() -> Int {
        totalCallCount
    }

    func getCall(forChunk index: Int) -> MockProviderCall? {
        callsByChunk[index]
    }

    func getCalls() -> [Int: MockProviderCall] {
        callsByChunk
    }

    func getVoicesInChunkOrder() -> [String] {
        callsByChunk.keys.sorted().compactMap { callsByChunk[$0]?.voice }
    }
}

actor ReverseDelayProvider: TTSProvider {
    let config: TTSProviderConfig
    private var callCount = 0
    private let totalChunks: Int
    private let delayPerChunk: Duration

    init(
        totalChunks: Int,
        config: TTSProviderConfig = TTSProviderConfig(
            maxChunkCharacters: 20,
            defaultVoice: "alloy",
            defaultFormat: .wav
        ),
        delayPerChunk: Duration = .milliseconds(20)
    ) {
        self.totalChunks = totalChunks
        self.config = config
        self.delayPerChunk = delayPerChunk
    }

    func generate(
        text: String,
        voice _: String,
        options _: TTSOptions,
        context _: TTSChunkContext
    ) async throws -> Data {
        let index = callCount
        callCount += 1
        try await Task.sleep(for: delayPerChunk * (totalChunks - index))
        return Data(text.utf8)
    }
}

actor ConcurrencyTracker: TTSProvider {
    let config: TTSProviderConfig
    private let wrapped: MockTTSProvider
    private var currentConcurrent = 0
    private var peakConcurrent = 0

    init(wrapped: MockTTSProvider) {
        config = wrapped.config
        self.wrapped = wrapped
    }

    func generate(
        text: String,
        voice: String,
        options: TTSOptions,
        context: TTSChunkContext
    ) async throws -> Data {
        currentConcurrent += 1
        if currentConcurrent > peakConcurrent {
            peakConcurrent = currentConcurrent
        }

        let data = try await wrapped.generate(
            text: text,
            voice: voice,
            options: options,
            context: context
        )

        currentConcurrent -= 1
        return data
    }

    func getPeakConcurrent() -> Int {
        peakConcurrent
    }
}

let mp3WrapperHeader = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
let mp3WrapperTail: Data = {
    var tail = Data([0x54, 0x41, 0x47])
    tail.append(contentsOf: [UInt8](repeating: 0x00, count: 125))
    return tail
}()

func wrapInMP3Metadata(_ text: String) -> Data {
    var data = mp3WrapperHeader
    data.append(Data(text.utf8))
    data.append(mp3WrapperTail)
    return data
}

func markerPCMData(for text: String) -> Data {
    let marker = UInt8(text.utf8.reduce(0) { ($0 + Int($1)) % 251 })
    return Data(repeating: marker, count: text.utf8.count * 3)
}

func alignedPCMData(for text: String) -> Data {
    let marker = UInt8(text.utf8.reduce(0) { ($0 + Int($1)) % 251 })
    return Data(repeating: marker, count: text.utf8.count * 4)
}

func tonePCM(for text: String) -> Data {
    let hash = text.utf8.reduce(0) { $0 &+ Int($1) }
    return tonePCM(amplitude: 0.15 + Double(hash % 5) * 0.05, frames: 24000)
}

func tonePCM(amplitude: Double, frames: Int) -> Data {
    var data = Data(capacity: frames * 2)
    for index in 0 ..< frames {
        let sample = amplitude * sin(2 * .pi * 1000 * Double(index) / 24000)
        let bits = UInt16(bitPattern: Int16((sample * 32767.0).rounded()))
        data.append(UInt8(bits & 0x00FF))
        data.append(UInt8(bits >> 8))
    }
    return data
}

enum CoordinationStop: Error, Equatable {
    case runEndedBeforeStart(index: Int)
    case endedBeforeCount(received: Int, expected: Int)
}

actor SegmentCollector {
    private var segments: [TTSSegment] = []
    private var waiters: [Int: [CheckedContinuation<Void, any Error>]] = [:]
    private var finished = false
    private var failure: (any Error)?

    func append(_ segment: TTSSegment) {
        segments.append(segment)
        let pending = waiters.removeValue(forKey: segments.count) ?? []
        for continuation in pending {
            continuation.resume()
        }
    }

    func finish(failure: (any Error)?) {
        finished = true
        self.failure = failure
        let pending = waiters
        waiters = [:]
        for (expected, continuations) in pending {
            for continuation in continuations {
                continuation.resume(
                    throwing: failure ?? CoordinationStop.endedBeforeCount(received: segments.count, expected: expected)
                )
            }
        }
    }

    func waitForCount(_ count: Int) async throws {
        try await withCheckedThrowingContinuation { continuation in
            if segments.count >= count {
                continuation.resume()
            } else if finished {
                continuation.resume(
                    throwing: failure ?? CoordinationStop.endedBeforeCount(received: segments.count, expected: count)
                )
            } else {
                waiters[count, default: []].append(continuation)
            }
        }
    }

    func recorded() -> [TTSSegment] {
        segments
    }
}

func collectStream(
    _ stream: AsyncThrowingStream<TTSSegment, Error>,
    into collector: SegmentCollector,
    onStreamEnd: @escaping @Sendable () async -> Void = {}
) -> Task<(any Error)?, Never> {
    Task {
        var failure: (any Error)?
        do {
            for try await segment in stream {
                await collector.append(segment)
            }
        } catch {
            failure = error
        }
        await onStreamEnd()
        await collector.finish(failure: failure)
        return failure
    }
}

actor GatedTTSProvider: TTSProvider {
    struct Call: Hashable {
        let voice: String
        let index: Int
    }

    let config: TTSProviderConfig
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    private let dataFactory: @Sendable (String) -> Data
    private var responses: [Int: Result<Data, any Error>]
    private let gatedCalls: Set<Call>

    private var started: [Call] = []
    private var released: Set<Call> = []
    private var completions: [Call: Bool] = [:]
    private var runEnded = false
    private var startWaiters: [Call: [CheckedContinuation<Void, any Error>]] = [:]
    private var releaseWaiters: [Call: [CheckedContinuation<Void, Never>]] = [:]
    private var completionWaiters: [Call: [CheckedContinuation<Bool, Never>]] = [:]

    init(
        sampleRate: Int = 24000,
        channels: Int = 1,
        bitsPerSample: Int = 16,
        maxChunkCharacters: Int = 20,
        defaultVoice: String = "alloy",
        gatedCalls: Set<Call> = [],
        responses: [Int: Result<Data, any Error>] = [:],
        dataFactory: @Sendable @escaping (String) -> Data = alignedPCMData(for:)
    ) {
        config = TTSProviderConfig(
            maxChunkCharacters: maxChunkCharacters,
            defaultVoice: defaultVoice,
            defaultFormat: .pcm
        )
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.gatedCalls = gatedCalls
        self.responses = responses
        self.dataFactory = dataFactory
    }

    nonisolated func resolvedEncoding(for format: TTSAudioFormat, options _: TTSOptions) -> TTSAudioEncoding {
        switch format {
        case .pcm:
            TTSAudioEncoding(format, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample)
        case .mp3, .opus, .aac, .flac, .wav:
            TTSAudioEncoding(format)
        }
    }

    func generate(
        text: String,
        voice: String,
        options _: TTSOptions,
        context: TTSChunkContext
    ) async throws -> Data {
        let call = Call(voice: voice, index: context.chunk.index)
        started.append(call)
        resumeAll(&startWaiters[call, default: []])
        if gatedCalls.contains(call) {
            // Cancellation opens the gate, but the late response still exercises the receiver's cancellation check.
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released.contains(call) {
                        continuation.resume()
                    } else {
                        releaseWaiters[call, default: []].append(continuation)
                    }
                }
            } onCancel: {
                Task { await self.release(call) }
            }
        }
        let wasCancelled = Task.isCancelled
        completions[call] = wasCancelled
        resumeAll(&completionWaiters[call, default: []], returning: wasCancelled)
        if let result = responses[context.chunk.index] {
            return try result.get()
        }
        return dataFactory(text)
    }

    func awaitStarted(_ call: Call) async throws {
        try await withCheckedThrowingContinuation { continuation in
            if started.contains(call) {
                continuation.resume()
            } else if runEnded {
                continuation.resume(throwing: CoordinationStop.runEndedBeforeStart(index: call.index))
            } else {
                startWaiters[call, default: []].append(continuation)
            }
        }
    }

    func endRun() {
        runEnded = true
        for call in Array(startWaiters.keys) {
            let pending = startWaiters.removeValue(forKey: call) ?? []
            for continuation in pending {
                if started.contains(call) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CoordinationStop.runEndedBeforeStart(index: call.index))
                }
            }
        }
    }

    func awaitCompletion(_ call: Call) async -> Bool {
        await withCheckedContinuation { continuation in
            if let wasCancelled = completions[call] {
                continuation.resume(returning: wasCancelled)
            } else {
                completionWaiters[call, default: []].append(continuation)
            }
        }
    }

    func release(_ call: Call) {
        released.insert(call)
        resumeAll(&releaseWaiters[call, default: []])
    }

    func releaseAll() {
        for call in gatedCalls {
            released.insert(call)
        }
        for call in Array(releaseWaiters.keys) {
            resumeAll(&releaseWaiters[call, default: []])
        }
    }

    func startedCalls() -> [Call] {
        started
    }

    private func resumeAll(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let pending = waiters
        waiters = []
        for continuation in pending {
            continuation.resume()
        }
    }

    private func resumeAll(_ waiters: inout [CheckedContinuation<Void, any Error>]) {
        let pending = waiters
        waiters = []
        for continuation in pending {
            continuation.resume()
        }
    }

    private func resumeAll(_ waiters: inout [CheckedContinuation<Bool, Never>], returning value: Bool) {
        let pending = waiters
        waiters = []
        for continuation in pending {
            continuation.resume(returning: value)
        }
    }
}

actor EncodingAwarePCMProvider: TTSProvider {
    let config: TTSProviderConfig
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    private let dataFactory: @Sendable (String) -> Data
    private var responses: [Int: Result<Data, any Error>]
    private(set) var generateCallCount = 0

    init(
        sampleRate: Int = 24000,
        channels: Int = 1,
        bitsPerSample: Int = 16,
        maxChunkCharacters: Int = 20,
        defaultVoice: String = "alloy",
        responses: [Int: Result<Data, any Error>] = [:],
        dataFactory: @Sendable @escaping (String) -> Data = markerPCMData(for:)
    ) {
        config = TTSProviderConfig(
            maxChunkCharacters: maxChunkCharacters,
            defaultVoice: defaultVoice,
            defaultFormat: .pcm
        )
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.responses = responses
        self.dataFactory = dataFactory
    }

    nonisolated func resolvedEncoding(for format: TTSAudioFormat, options _: TTSOptions) -> TTSAudioEncoding {
        switch format {
        case .pcm:
            TTSAudioEncoding(format, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample)
        case .mp3, .opus, .aac, .flac, .wav:
            TTSAudioEncoding(format)
        }
    }

    func generate(
        text: String,
        voice _: String,
        options _: TTSOptions,
        context: TTSChunkContext
    ) async throws -> Data {
        generateCallCount += 1
        if let result = responses[context.chunk.index] {
            return try result.get()
        }
        return dataFactory(text)
    }
}
