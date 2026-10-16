import Foundation

/// Why a successful refresh cannot honestly report a consumption delta.
/// These reasons deliberately contain no account identity or source path.
public enum QuotaUpdateReason: Equatable, Sendable {
    case initial, identityUnavailable, accountChanged, newWindow
    case durationChanged, resetChanged, increased, resetPending
    case stale, nonMonotonic, dataUnavailable, sourceChanged, previousReadFailed
}

public struct QuotaWindowUpdate: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        /// An absolute decrease in remaining allowance, never a relative percentage.
        case decreased(percentagePoints: Double)
        case unchanged
        case updated(reason: QuotaUpdateReason)
    }

    public let bucketID: String
    public let windowID: String
    public let change: Change
    /// True when fresh matching window reads contain different numeric quota.
    /// Missing optional identity/metadata permits a current-value notice only,
    /// never a consumption claim or a comparable source interval.
    public let hasNumericChange: Bool
}

/// One bounded refresh result. Only public bucket/window IDs reach presentation.
public struct QuotaUpdate: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case updated, unchanged, readFailed }
    public let kind: Kind
    public let windows: [QuotaWindowUpdate]
    public let observedAt: Date
    public let fetchedAt: Date?
    /// Present only when at least one window is comparable. The selected window's
    /// change must still be checked before presenting an interval or numeric delta.
    public let previousFetchedAt: Date?
    /// Explicit delivery boundary, distinct from "no new numeric event". UI must
    /// drop older pending/visible notices here, then may show this result's notice.
    public let invalidatesPreviousNotices: Bool

    public func window(bucketID: String, windowID: String) -> QuotaWindowUpdate? {
        windows.first { $0.bucketID == bucketID && $0.windowID == windowID }
    }

    /// Choose only a window whose quota actually changed. An unchanged preferred
    /// window must never mask or stand in for another window's numeric change.
    public func changedWindow(preferredBucketID: String? = nil, preferredWindowID: String? = nil) -> QuotaWindowUpdate? {
        guard kind != .readFailed else { return nil }
        if let preferredBucketID, let preferredWindowID,
           let preferred = windows.first(where: {
               $0.bucketID == preferredBucketID && $0.windowID == preferredWindowID && $0.hasNumericChange
           }) {
            return preferred
        }
        return windows.first { $0.hasNumericChange }
    }
}

/// Pure, in-memory comparison state: one previous snapshot, with no event history,
/// persistence, timers, requests or logs. Call once for each completed refresh.
public struct QuotaUpdateTracker: Sendable {
    public static let freshnessInterval: TimeInterval = 180
    /// One in-memory observation may support a current-value notice for at most
    /// a day. This never extends the 180-second consumption-comparison interval.
    public static let observationInterval: TimeInterval = 86_400
    private var baseline: QuotaSnapshot?
    private var nextReason: QuotaUpdateReason = .initial

    public init() {}

    /// Use whenever the selected/resolved helper changes, including a source-path edit.
    /// In-flight results from a previous source must be discarded by the caller.
    public mutating func invalidateSource() {
        baseline = nil
        nextReason = .sourceChanged
    }

    /// Transport failures retain one bounded last-success observation, not a
    /// consumption interval. Authentication, source and unclassified failures
    /// still invalidate it because account continuity cannot be established.
    public mutating func recordFailure(_ error: MeterError? = nil, at now: Date = Date()) -> QuotaUpdate {
        let transient = error == .timedOut || error == .disconnected
        if !transient || baseline.map({ !Self.isRecentObservation($0.fetchedAt, at: now) }) != false {
            baseline = nil
        }
        nextReason = .previousReadFailed
        return QuotaUpdate(kind: .readFailed, windows: [], observedAt: now, fetchedAt: nil, previousFetchedAt: nil, invalidatesPreviousNotices: true)
    }

    public mutating func record(_ snapshot: QuotaSnapshot, at now: Date) -> QuotaUpdate {
        let previous = baseline
        let commonReason = comparisonReason(previous: previous, current: snapshot, now: now)
        let currentIndex = WindowIndex(snapshot)
        let previousIndex = previous.map(WindowIndex.init)
        let updates = snapshot.buckets.flatMap { bucket in
            bucket.windows.map { window -> QuotaWindowUpdate in
                let key = WindowKey(bucketID: bucket.id, windowID: window.id)
                let change: QuotaWindowUpdate.Change
                let hasNumericChange: Bool
                if let commonReason {
                    change = .updated(reason: commonReason)
                    hasNumericChange = false
                } else if !currentIndex.isUnambiguous(key) || previousIndex?.isAmbiguous(key) == true {
                    change = .updated(reason: .dataUnavailable)
                    hasNumericChange = false
                } else if let oldWindow = previousIndex?.windows[key] {
                    let comparison: (change: QuotaWindowUpdate.Change, hasNumericChange: Bool)
                    if nextReason == .previousReadFailed {
                        comparison = Self.compareObservedValues(oldWindow, window, at: now, reason: .previousReadFailed)
                    } else if let previous, !Self.isFresh(previous.fetchedAt, at: now) {
                        comparison = Self.compareObservedValues(oldWindow, window, at: now, reason: .stale)
                    } else if snapshot.continuityIdentity == nil {
                        comparison = Self.compareObservedValues(oldWindow, window, at: now, reason: .identityUnavailable)
                    } else if (oldWindow.durationMinutes == nil && window.durationMinutes == nil)
                        || (oldWindow.resetsAt == nil && window.resetsAt == nil) {
                        comparison = Self.compareObservedValues(oldWindow, window, at: now, reason: .dataUnavailable)
                    } else {
                        comparison = Self.compare(oldWindow, window, at: now)
                    }
                    change = comparison.change
                    hasNumericChange = comparison.hasNumericChange
                } else {
                    change = .updated(reason: .newWindow)
                    hasNumericChange = false
                }
                return QuotaWindowUpdate(bucketID: bucket.id, windowID: window.id,
                                         change: change, hasNumericChange: hasNumericChange)
            }
        }

        // Invalid timing cannot become a baseline: a replay or future/stale response
        // must not make the next valid result look like additional consumption.
        if !Self.isFresh(snapshot.fetchedAt, at: now) || (previous != nil && commonReason == .nonMonotonic) {
            baseline = nil
            nextReason = commonReason ?? .stale
        } else {
            baseline = snapshot
            nextReason = .initial
        }
        let sameWindowSet = previousIndex.map { $0.keys == currentIndex.keys } ?? false
        let windowBoundary = currentIndex.windows.contains { key, current in
            guard currentIndex.isUnambiguous(key), previousIndex?.isAmbiguous(key) != true,
                  let old = previousIndex?.windows[key] else { return true }
            return old.remainingPercent == nil || current.remainingPercent == nil
                || old.durationMinutes != current.durationMinutes || old.resetsAt != current.resetsAt
                || current.resetPending(at: now)
                || current.resetsAt.map { !$0.timeIntervalSince1970.isFinite } == true
        }
        let invalidatesNotices = commonReason != nil || !sameWindowSet || windowBoundary
        let unchanged = !updates.isEmpty && sameWindowSet && updates.allSatisfy { $0.change == .unchanged }
        let hasComparableWindow = updates.contains { update in
            switch update.change {
            case .decreased, .unchanged: return true
            case .updated: return false
            }
        }
        return QuotaUpdate(kind: unchanged ? .unchanged : .updated, windows: updates,
                           observedAt: now, fetchedAt: snapshot.fetchedAt,
                           previousFetchedAt: hasComparableWindow ? previous?.fetchedAt : nil,
                           invalidatesPreviousNotices: invalidatesNotices)
    }

    private func comparisonReason(previous: QuotaSnapshot?, current: QuotaSnapshot, now: Date) -> QuotaUpdateReason? {
        guard Self.isFresh(current.fetchedAt, at: now) else { return .stale }
        guard let previous else { return current.continuityIdentity == nil ? .identityUnavailable : nextReason }
        let elapsed = current.fetchedAt.timeIntervalSince(previous.fetchedAt)
        guard elapsed.isFinite, elapsed > 0 else { return .nonMonotonic }
        guard Self.isRecentObservation(previous.fetchedAt, at: now) else { return .stale }
        switch (previous.continuityIdentity, current.continuityIdentity) {
        case (nil, nil):
            // Older backends legitimately omit accountId; the parser also treats
            // malformed optional identity as unavailable. Numeric observation is
            // still useful, but compareObservedValues cannot claim consumption.
            break
        case (.some(let old), .some(let new)):
            if old != new { return .accountChanged }
        default:
            // Identity appearing/disappearing is a baseline boundary, not a delta.
            return .identityUnavailable
        }
        return nil
    }

    private static func isRecentObservation(_ fetchedAt: Date, at now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return now.timeIntervalSince1970.isFinite && fetchedAt.timeIntervalSince1970.isFinite
            && age.isFinite && age >= 0 && age <= observationInterval
    }

    private static func isFresh(_ fetchedAt: Date, at now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return now.timeIntervalSince1970.isFinite && fetchedAt.timeIntervalSince1970.isFinite
            && age.isFinite && age >= 0 && age <= freshnessInterval
    }

    /// Compatibility path for optional backend fields. Only the current value is
    /// presented; equal optional metadata means "not known to have changed", not
    /// proof of account, duration or reset continuity. Invalid numeric quota,
    /// changed duration, one-sided metadata loss and due resets stay silent.
    private static func compareObservedValues(_ previous: QuotaWindow, _ current: QuotaWindow,
        at now: Date, reason: QuotaUpdateReason)
        -> (change: QuotaWindowUpdate.Change, hasNumericChange: Bool) {
        let silent: (QuotaWindowUpdate.Change, Bool) = (.updated(reason: reason), false)
        guard previous.durationMinutes == current.durationMinutes else { return silent }
        switch (previous.resetsAt, current.resetsAt) {
        case (nil, nil): break
        case (.some(let old), .some(let new)):
            guard old.timeIntervalSince1970.isFinite, new.timeIntervalSince1970.isFinite,
                  new > now else { return silent }
        default: return silent
        }
        guard let old = previous.remainingPercent, let new = current.remainingPercent else { return silent }
        return (.updated(reason: reason), old != new)
    }

    private static func compare(_ previous: QuotaWindow, _ current: QuotaWindow, at now: Date)
        -> (change: QuotaWindowUpdate.Change, hasNumericChange: Bool) {
        guard let oldDuration = previous.durationMinutes, let newDuration = current.durationMinutes,
              oldDuration > 0, newDuration > 0 else { return (.updated(reason: .dataUnavailable), false) }
        guard oldDuration == newDuration else { return (.updated(reason: .durationChanged), false) }
        guard let oldReset = previous.resetsAt, let newReset = current.resetsAt,
              oldReset.timeIntervalSince1970.isFinite, newReset.timeIntervalSince1970.isFinite else {
            return (.updated(reason: .dataUnavailable), false)
        }
        guard newReset > now else { return (.updated(reason: .resetPending), false) }
        if oldReset != newReset {
            // A newly confirmed future cycle may change quota even when the old
            // reset is already due. It never establishes a consumption interval.
            let numericChange: Bool
            if let oldRemaining = previous.remainingPercent, let newRemaining = current.remainingPercent {
                numericChange = oldRemaining != newRemaining
            } else {
                numericChange = false
            }
            return (.updated(reason: .resetChanged), numericChange)
        }
        guard let oldRemaining = previous.remainingPercent, let newRemaining = current.remainingPercent else {
            return (.updated(reason: .dataUnavailable), false)
        }
        if newRemaining < oldRemaining {
            return (.decreased(percentagePoints: oldRemaining - newRemaining), true)
        }
        if newRemaining > oldRemaining { return (.updated(reason: .increased), true) }
        return (.unchanged, false)
    }

    private struct WindowKey: Hashable {
        let bucketID: String
        let windowID: String
    }

    /// Duplicated/missing IDs are never silently paired by array position.
    private struct WindowIndex {
        var windows: [WindowKey: QuotaWindow] = [:]
        var duplicateWindows: Set<WindowKey> = []
        var duplicateBuckets: Set<String> = []
        var keys: Set<WindowKey> { Set(windows.keys) }

        init(_ snapshot: QuotaSnapshot) {
            var bucketIDs: Set<String> = []
            for bucket in snapshot.buckets {
                if !bucketIDs.insert(bucket.id).inserted { duplicateBuckets.insert(bucket.id) }
                for window in bucket.windows {
                    let key = WindowKey(bucketID: bucket.id, windowID: window.id)
                    if windows.updateValue(window, forKey: key) != nil { duplicateWindows.insert(key) }
                }
            }
        }

        func isAmbiguous(_ key: WindowKey) -> Bool {
            key.bucketID.isEmpty || key.windowID.isEmpty
                || duplicateBuckets.contains(key.bucketID) || duplicateWindows.contains(key)
        }

        func isUnambiguous(_ key: WindowKey) -> Bool { windows[key] != nil && !isAmbiguous(key) }
    }
}
