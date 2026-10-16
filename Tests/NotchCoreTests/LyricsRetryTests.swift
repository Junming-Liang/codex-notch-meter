import XCTest
@testable import NotchCore

final class LyricsRetryTests: XCTestCase {
    func testTransientFailureIsNotNoMatch() {
        XCTAssertEqual(LyricsLookupState.failure(.serviceUnavailable(retryAfter: 60)), .serviceUnavailable)
        XCTAssertEqual(LyricsLookupState.failure(.rateLimited(retryAfter: 60)), .rateLimited)
        XCTAssertEqual(LyricsLookupState.failure(.offline), .temporaryFailure)
        XCTAssertEqual(LyricsLookupState.failure(.identityMismatch), .identityMismatch)
        XCTAssertNotEqual(LyricsLookupState.failure(.invalidResponse), .noMatch)
    }
    func testServerCooldownIsNeverShortened() {
        XCTAssertEqual(LyricsRetryPolicy.nextAttemptAt(after: .serviceUnavailable(retryAfter: 60), completedAttempts: 1, now: 100), 160)
        XCTAssertEqual(LyricsRetryPolicy.nextAttemptAt(after: .rateLimited(retryAfter: 7200), completedAttempts: 2, now: 100), 7300)
        XCTAssertEqual(LyricsRetryPolicy.nextAttemptAt(after: .serviceUnavailable(retryAfter: 1), completedAttempts: 1, now: 100), 130)
    }
    func testNetworkBackoffHasOnlyTwoAutomaticRetries() {
        XCTAssertEqual(LyricsRetryPolicy.nextAttemptAt(after: .offline, completedAttempts: 1, now: 100), 130)
        XCTAssertEqual(LyricsRetryPolicy.nextAttemptAt(after: .timedOut, completedAttempts: 2, now: 130), 190)
        XCTAssertNil(LyricsRetryPolicy.nextAttemptAt(after: .transportFailure, completedAttempts: 3, now: 190))
        XCTAssertNil(LyricsRetryPolicy.nextAttemptAt(after: .offline, completedAttempts: 0, now: 0))
    }
    func testUnsafeOrUnusableContentDoesNotRetry() {
        for error in [LyricsLookupError.identityMismatch, .invalidLyrics, .tooLarge,
                      .consentRequired, .cancelled, .requestNotAllowed, .invalidTrack] {
            XCTAssertNil(LyricsRetryPolicy.nextAttemptAt(after: error, completedAttempts: 1, now: 100))
        }
    }
    func testCooldownRemainsEvenAfterAutomaticAttemptBudgetIsExhausted() {
        XCTAssertNil(LyricsRetryPolicy.nextAttemptAt(after: .offline, completedAttempts: 3, now: 100))
        XCTAssertEqual(LyricsRetryPolicy.cooldownUntil(after: .offline, completedAttempts: 3, now: 100), 220)
        XCTAssertEqual(LyricsRetryPolicy.cooldownUntil(after: .offline, completedAttempts: Int.max, now: 100), 400)
        XCTAssertEqual(LyricsRetryPolicy.cooldownUntil(after: .serviceUnavailable(retryAfter: 600), completedAttempts: 3, now: 100), 700)
    }
    func testInvalidClockAndOverflowFailClosed() {
        for now in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(LyricsRetryPolicy.nextAttemptAt(after: .offline, completedAttempts: 1, now: now))
        }
        XCTAssertNil(LyricsRetryPolicy.nextAttemptAt(after: .rateLimited(retryAfter: .greatestFiniteMagnitude), completedAttempts: 1, now: .greatestFiniteMagnitude))
        XCTAssertEqual(LyricsRetryPolicy.nextAttemptAt(after: .serviceUnavailable(retryAfter: .nan), completedAttempts: 1, now: 100), 160)
    }
}
