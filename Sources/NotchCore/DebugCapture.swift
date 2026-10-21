import Foundation

/// Opt-in diagnostic data boundary. No arbitrary text, account/model values,
/// paths, song metadata, or absolute screen/pointer positions can be encoded.
/// The caller owns serialization (main actor in the app); no worker or timer is
/// created here. All buffers, sampling lanes and identifier maps are bounded.
public final class DebugCapture {
    public enum Event: String, CaseIterable, Codable {
        case geometry, pollTick, inputIngress, pollIngress, input, hover, ownership, frame, frameCallback, width, music, gate, lifecycle
    }
    public enum Field: String, CaseIterable, Codable {
        case island, deliveredOffsetMs, decisionOffsetMs, sourceOffsetMs, sourceAgeMs, scheduledOffsetMs, elapsedMs, applyMs
        case progress, target, velocity, accessory, accessoryTarget, widthBridge
        case width, height, centerOffset, topError, screenWidth, screenHeight, scale
        case notchWidth, notchHeight, horizontalAdjustment, widthAdjustment, depthAdjustment, cornerAdjustment
        case pointerX, pointerY, anchorX, anchorY, inside, expandedBefore, expandedAfter
        case reserved, gestureGate, corridorExitRequired, fresh, playing, lyricsMode, enabled
        case presentationRevision, playbackRevision, noticeRevision, frameRevision
        case settings, menu, popover, allowed, quotaError, quotaStale, reducedMotion
        case frameGapMs, eventGapMs, pollGapMs, rawPollGapMs, readMs
    }
    public enum Label: String, Codable { case source, owner, previousOwner, reason, outcome, readPhase, readFailure, lookup }
    public enum Value: String, Codable {
        case idle, music, quotaNotice, details
        case localEvent, globalEvent, poll, synthetic, displayLink, dispatchTimer, timer, unknown
        case snapshot, accepted, staleEvent, duplicateEvent, quietWindow, invalid, button
        case noticeOwns, gestureAccepted, gestureUnavailable, reserved, gestureGate, dwellReset, hoverDecision
        case enter, leave, retarget, accessoryChanged, bridgeChanged, geometryChanged
        case musicChanged, gateChanged, noticeShown, noticeDismissed, noticeExpired, collapse, stopped
        case ready, timedOut, target, permission, stateBefore, trackBefore, position, trackAfter, stateAfter, validation
        case none, notRunning, denied, timeout, malformed, changedTrack, unavailable, failed
        case loading, matched, noMatch, invalidMetadata, identityMismatch, rateLimited, serviceUnavailable, temporaryFailure, rejected
    }
    public enum Counter: String, CaseIterable, Codable {
        case localEvents, globalEvents, pollCallbacks, polls, acceptedPolls, quietPolls, rejectedEvents, hoverDecisions, frameCallbacks, frameApplies
        case sampledOut, rateLimited, evicted, oversized, invalidFields, identifierOverflow, encodingFailures
    }
    public enum StopReason: String, Codable { case manual, durationLimit, applicationExit }
    public enum ExportError: Error { case noCapture, stillRecording, encodingFailed }
    public struct Metadata {
        public let version: String
        public let build: String
        public init(version: String, build: String) {
            // Bundle strings are not a general-purpose logging channel.
            func safe(_ input: String) -> String {
                let allowed = Set("0123456789.")
                return !input.isEmpty && input.count <= 32 && input.allSatisfy { allowed.contains($0) } ? input : "unknown"
            }
            self.version = safe(version); self.build = safe(build)
        }
    }
    private struct Row: Encodable {
        let sequence: UInt64
        let elapsedMs: Double
        let event: Event
        let values: [String: Double]
        let labels: [String: Value]
    }
    public static let maximumBytes = 2 * 1024 * 1024
    public static let maximumDuration: TimeInterval = 300
    public var didStop: (() -> Void)?
    public private(set) var isRecording = false
    public private(set) var hasCapture = false
    public private(set) var counters: [Counter: UInt64] = [:]
    public private(set) var storedBytes = 0
    public private(set) var storedEvents = 0
    public var durationLimit: TimeInterval { duration }
    public private(set) var stopReason: StopReason?
    public private(set) var sessionID = UUID()
    private let clock: () -> TimeInterval
    private let capacity: Int
    private let duration: TimeInterval
    private let byteLimit: Int
    private var started: TimeInterval = 0
    private var lastElapsed: Double = 0
    private var endedElapsed: Double = 0
    private var metadata = Metadata(version: "", build: "")
    private var rows: [Data?]
    private var head = 0
    private var sequence: UInt64 = 0
    private struct Lane: Hashable { let event: Event; let island: UInt64 }
    private var sampledAt: [Lane: TimeInterval] = [:]
    private var identifiers: [UUID: UInt64] = [:]
    private var geometryContext: [UInt64: Row] = [:]
    private var budgetSecond = -1
    private var budgetCount = 0
    private let encoder = JSONEncoder()
    private var recordWorkMs: Double = 0
    private var maximumRecordWorkMs: Double = 0
    private var measuredRecords: UInt64 = 0

    public init(maximumBytes: Int = DebugCapture.maximumBytes, maximumEvents: Int = 4096,
                duration: TimeInterval = DebugCapture.maximumDuration,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        self.capacity = min(4096, max(1, maximumEvents))
        self.byteLimit = min(Self.maximumBytes, max(16_384, maximumBytes)) - 8192
        self.duration = duration.isFinite ? min(Self.maximumDuration, max(0.01, duration)) : Self.maximumDuration
        rows = []
        encoder.outputFormatting = [.sortedKeys]
    }
    public func start(metadata: Metadata) {
        self.metadata = metadata; sessionID = UUID(); started = clock()
        lastElapsed = 0; endedElapsed = 0; head = 0; sequence = 0
        rows = Array(repeating: nil, count: capacity); storedEvents = 0; storedBytes = 0
        counters.removeAll(keepingCapacity: true); sampledAt.removeAll(keepingCapacity: true)
        identifiers.removeAll(keepingCapacity: true); geometryContext.removeAll(keepingCapacity: true); budgetSecond = -1; budgetCount = 0
        recordWorkMs = 0; maximumRecordWorkMs = 0; measuredRecords = 0
        stopReason = nil; hasCapture = true; isRecording = true
    }
    @discardableResult public func expireIfNeeded() -> Bool {
        guard isRecording else { return false }
        if clock() - started >= duration { stop(reason: .durationLimit); return true }
        return false
    }
    public func stop(reason: StopReason = .manual) {
        guard isRecording else { return }
        endedElapsed = max(lastElapsed, max(0, (clock() - started) * 1000))
        stopReason = reason; isRecording = false
        didStop?()
    }
    public func count(_ counter: Counter) {
        guard isRecording, !expireIfNeeded() else { return }
        counters[counter, default: 0] &+= 1
    }
    /// Random process-local UUIDs only. Returned IDs restart at 1 each capture.
    /// Unknown/overflow is 0; unbounded IDs are never retained.
    public func identifier(_ token: UUID) -> Double {
        guard isRecording else { return 0 }
        if let value = identifiers[token] { return Double(value) }
        guard identifiers.count < 512 else { count(.identifierOverflow); return 0 }
        let value = UInt64(identifiers.count + 1); identifiers[token] = value
        return Double(value)
    }
    public func offsetMilliseconds(_ uptime: TimeInterval) -> Double { (uptime - started) * 1000 }

    /// Sample high-frequency events at at most 10 Hz per event/island. Critical
    /// state edges use sampled=false but still share a hard 120-row/second cap.
    /// Autoclosures are not evaluated while disabled or after rate limiting.
    public func record(_ event: Event, island: Double = 0, sampled: Bool = false,
                       values: @autoclosure () -> [Field: Double] = [:],
                       labels: @autoclosure () -> [Label: Value] = [:]) {
        guard isRecording, !expireIfNeeded() else { return }
        let now = clock(), elapsed = max(lastElapsed, max(0, (now - started) * 1000))
        let safeIsland = island.isFinite && island >= 0 && island <= 512 ? UInt64(island) : 0
        let lane = Lane(event: event, island: safeIsland)
        if sampled, let previous = sampledAt[lane], now - previous < 0.1 {
            count(.sampledOut); return
        }
        let second = Int(min(1_000_000, elapsed / 1000))
        if second != budgetSecond { budgetSecond = second; budgetCount = 0 }
        guard budgetCount < 120 else { count(.rateLimited); return }
        if sampled {
            // Sampling lanes are capped independently of identifier allocation.
            guard sampledAt[lane] != nil || sampledAt.count < 256 else { count(.rateLimited); return }
            sampledAt[lane] = now
        }
        budgetCount += 1
        // Measure accepted-row payload + encode + ring work, not frame latency.
        // Sampling checks/caller instrumentation are excluded and documented.
        let workStarted = ProcessInfo.processInfo.systemUptime
        defer {
            let work = max(0, (ProcessInfo.processInfo.systemUptime - workStarted) * 1000)
            recordWorkMs += work; maximumRecordWorkMs = max(maximumRecordWorkMs, work)
            measuredRecords &+= 1
        }
        var numbers: [String: Double] = [:]
        for (field, value) in values() {
            // Bound corruption and serialization cost; geometric values remain
            // useful in points without exposing raw desktop origins.
            guard value.isFinite, abs(value) <= 10_000_000 else { count(.invalidFields); continue }
            if [.pointerX, .pointerY, .anchorX, .anchorY].contains(field), abs(value) > 1024 {
                count(.invalidFields); continue
            }
            numbers[field.rawValue] = (value * 1000).rounded() / 1000
        }
        numbers[Field.island.rawValue] = Double(safeIsland)
        sequence &+= 1; lastElapsed = elapsed
        let row = Row(sequence: sequence, elapsedMs: elapsed, event: event, values: numbers,
                      labels: Dictionary(uniqueKeysWithValues: labels().map { ($0.key.rawValue, $0.value) }))
        if event == .geometry {
            let fields: Set<Field> = [.island, .screenWidth, .screenHeight, .scale, .notchWidth, .notchHeight,
                .horizontalAdjustment, .widthAdjustment, .depthAdjustment, .cornerAdjustment, .reducedMotion]
            let safe = numbers.filter { key, _ in Field(rawValue: key).map { fields.contains($0) } ?? false }
            // Partial/misclassified rows must never erase the last full context.
            if Set(safe.keys) == Set(fields.map(\.rawValue)) {
                if geometryContext[safeIsland] == nil, geometryContext.count >= 8,
                   let oldest = geometryContext.min(by: { $0.value.sequence < $1.value.sequence })?.key {
                    geometryContext.removeValue(forKey: oldest)
                }
                geometryContext[safeIsland] = Row(sequence: sequence, elapsedMs: elapsed, event: event, values: safe, labels: [:])
            }
        }
        guard var data = try? encoder.encode(row) else { count(.encodingFailures); return }
        data.append(0x0a)
        guard data.count <= byteLimit else { count(.oversized); return }
        while storedEvents > 0 && (storedEvents == capacity || storedBytes + data.count > byteLimit) {
            storedBytes -= rows[head]?.count ?? 0; rows[head] = nil
            head = (head + 1) % capacity; storedEvents -= 1; count(.evicted)
        }
        rows[(head + storedEvents) % capacity] = data
        storedEvents += 1; storedBytes += data.count
    }
    public func exportData() throws -> Data {
        guard hasCapture else { throw ExportError.noCapture }
        guard !isRecording else { throw ExportError.stillRecording }
        struct Header: Encodable {
            let schema = "codex-notch-debug/1"
            let kind = "schema"
            let session: UUID
            let version: String
            let build: String
            let durationLimitSeconds: Double
            let byteLimit: Int
            let latestGeometryContext: [Row]
            let timing = "elapsedMs=actual monotonic observation; sourceOffsetMs=event uptime; scheduledOffsetMs=frame scheduler clock, all relative to capture start, not wall time"
        }
        struct Summary: Encodable {
            let kind = "summary"
            let elapsedMs: Double
            let stopReason: StopReason?
            let retainedEvents: Int
            let recordWorkMs: Double
            let maximumRecordWorkMs: Double
            let measuredRecords: UInt64
            let counters: [String: UInt64]
        }
        var output = try encoder.encode(Header(session: sessionID, version: metadata.version, build: metadata.build,
                                              durationLimitSeconds: duration, byteLimit: byteLimit + 8192,
                                              latestGeometryContext: geometryContext.keys.sorted().compactMap { geometryContext[$0] }))
        output.append(0x0a)
        for index in 0..<storedEvents {
            if let data = rows[(head + index) % capacity] { output.append(data) }
        }
        output.append(try encoder.encode(Summary(elapsedMs: endedElapsed, stopReason: stopReason,
            retainedEvents: storedEvents, recordWorkMs: recordWorkMs, maximumRecordWorkMs: maximumRecordWorkMs,
            measuredRecords: measuredRecords, counters: Dictionary(uniqueKeysWithValues: counters.map { ($0.key.rawValue, $0.value) }))))
        output.append(0x0a)
        guard output.count <= byteLimit + 8192 else { throw ExportError.encodingFailed }
        return output
    }
    /// The only write boundary. Call only after an explicit native Save action.
    /// A throwing writer retains the session for retry and never transmits it.
    public func export(using writer: (Data) throws -> Void) throws { try writer(exportData()) }
}
