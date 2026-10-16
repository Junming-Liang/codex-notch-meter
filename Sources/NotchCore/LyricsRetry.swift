import Foundation

/// A lookup failure is not a confirmed absence of lyrics. Keep its category
/// through ordinary playback samples; all text remains a user-safe fixed label.
public enum LyricsLookupState: Equatable, Sendable {
    case idle, loading, matched, noMatch, unavailable, invalidMetadata
    case identityMismatch, rateLimited, serviceUnavailable, temporaryFailure, rejected

    public static func failure(_ error: LyricsLookupError) -> Self {
        switch error {
        case .identityMismatch: return .identityMismatch
        case .rateLimited: return .rateLimited
        case .serviceUnavailable: return .serviceUnavailable
        case .offline, .timedOut, .transportFailure, .busy, .invalidResponse: return .temporaryFailure
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
        guard now.isFinite, completedAttempts > 0, completedAttempts < maximumAttempts else { return nil }
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
        case .offline, .timedOut, .transportFailure, .busy, .invalidResponse:
            delay = min(300, 30 * pow(2, Double(min(completedAttempts - 1, 4))))
        default: return nil
        }
        let result = now + delay
        return result.isFinite && result > now ? result : nil
    }
}
