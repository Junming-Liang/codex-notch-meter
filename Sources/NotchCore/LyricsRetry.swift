import Foundation

/// A lookup failure is not a confirmed absence of lyrics. Keep its category
/// through ordinary playback samples; all text remains a user-safe fixed label.
public enum LyricsLookupState: Equatable, Sendable {
    case idle, loading, waitingForProvider, matched, noMatch, unavailable, invalidMetadata
    case identityMismatch, searchResultsTruncated, rateLimited, serviceUnavailable, temporaryFailure, rejected

    public static func failure(_ error: LyricsLookupError) -> Self {
        switch error {
        case .identityMismatch: return .identityMismatch
        case .searchResultsTruncated: return .searchResultsTruncated
        case .busy, .deferred: return .waitingForProvider
        case .rateLimited: return .rateLimited
        case .serviceUnavailable: return .serviceUnavailable
        case .offline, .timedOut, .transportFailure, .invalidResponse: return .temporaryFailure
        case .invalidTrack: return .invalidMetadata
        default: return .rejected
        }
    }
}

/// At most two automatic retries after the initial lookup for a track revision.
/// Polling only checks eligibility; there is no additional timer or tight loop.
public enum LyricsRetryPolicy {
    public static let maximumAttempts = 3
    public static func nextAttemptAt(after error: LyricsLookupError, completedAttempts: Int,
                                     now: TimeInterval) -> TimeInterval? {
        guard now.isFinite else { return nil }
        // Local contention/spacing does not consume the network-attempt budget
        // and must not impose a cooldown on a later track. A retired in-flight
        // request still owns its slot until it completes or cancellation returns.
        let localDelay: TimeInterval?
        switch error {
        case .busy: localDelay = LRCLIBLookup.minimumRequestGap
        case .deferred(let delay):
            localDelay = max(LRCLIBLookup.minimumRequestGap, delay.isFinite && delay >= 0 ? delay : 0)
        default: localDelay = nil
        }
        if let localDelay {
            let deadline = now + localDelay
            return deadline.isFinite && deadline > now ? deadline : nil
        }
        guard completedAttempts > 0, completedAttempts < maximumAttempts else { return nil }
        return cooldownUntil(after: error, completedAttempts: completedAttempts, now: now)
    }

    /// A metadata-free cooldown survives song/source/consent invalidation, so
    /// invalidating a baseline cannot circumvent the provider failure backoff.
    public static func cooldownUntil(after error: LyricsLookupError, completedAttempts: Int,
                                      now: TimeInterval) -> TimeInterval? {
        guard now.isFinite, completedAttempts > 0 else { return nil }
        let delay: TimeInterval
        switch error {
        case .rateLimited(let server), .serviceUnavailable(let server):
            // Never shorten a valid server-specified cooldown. Local backoff has
            // a floor, but does not cap long Retry-After values.
            delay = max(30, server.isFinite && server >= 0 ? server : 60)
        case .offline, .timedOut, .transportFailure, .invalidResponse:
            delay = min(300, 30 * pow(2, Double(min(completedAttempts - 1, 4))))
        default: return nil
        }
        let result = now + delay
        return result.isFinite && result > now ? result : nil
    }
}
