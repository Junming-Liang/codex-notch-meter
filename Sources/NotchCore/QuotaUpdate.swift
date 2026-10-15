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

    public func window(bucketID: String, windowID: String) -> QuotaWindowUpdate? {
        windows.first { $0.bucketID == bucketID && $0.windowID == windowID }
    }
}

/// Pure, in-memory comparison state: one previous snapshot, with no event history,
/// persistence, timers, requests or logs. Call once for each completed refresh.
public struct QuotaUpdateTracker: Sendable {
    public static let freshnessInterval: TimeInterval = 180
    private var baseline: QuotaSnapshot?
    private var nextReason: QuotaUpdateReason = .initial

    public init() {}

    /// Use whenever the selected/resolved helper changes, including a source-path edit.
    /// In-flight results from a previous source must be discarded by the caller.
    public mutating func invalidateSource() {
        baseline = nil
        nextReason = .sourceChanged
    }

    /// Every failed read breaks continuity, even if the UI still displays cached values.
    public mutating func recordFailure(at now: Date = Date()) -> QuotaUpdate {
        baseline = nil
        nextReason = .previousReadFailed
        return QuotaUpdate(kind: .readFailed, windows: [], observedAt: now, fetchedAt: nil, previousFetchedAt: nil)
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
                if let commonReason {
                    change = .updated(reason: commonReason)
                } else if !currentIndex.isUnambiguous(key) || previousIndex?.isAmbiguous(key) == true {
                    change = .updated(reason: .dataUnavailable)
                } else if let oldWindow = previousIndex?.windows[key] {
                    change = Self.compare(oldWindow, window, at: now)
                } else {
                    change = .updated(reason: .newWindow)
                }
                return QuotaWindowUpdate(bucketID: bucket.id, windowID: window.id, change: change)
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
        let unchanged = !updates.isEmpty && sameWindowSet && updates.allSatisfy { $0.change == .unchanged }
        let hasComparableWindow = updates.contains { update in
            switch update.change {
            case .decreased, .unchanged: return true
            case .updated: return false
            }
        }
        return QuotaUpdate(kind: unchanged ? .unchanged : .updated, windows: updates,
                           observedAt: now, fetchedAt: snapshot.fetchedAt,
                           previousFetchedAt: hasComparableWindow ? previous?.fetchedAt : nil)
    }

    private func comparisonReason(previous: QuotaSnapshot?, current: QuotaSnapshot, now: Date) -> QuotaUpdateReason? {
        guard Self.isFresh(current.fetchedAt, at: now) else { return .stale }
        guard let previous else { return current.continuityIdentity == nil ? .identityUnavailable : nextReason }
        guard let oldIdentity = previous.continuityIdentity, let newIdentity = current.continuityIdentity else {
            return .identityUnavailable
        }
        guard oldIdentity == newIdentity else { return .accountChanged }
        let elapsed = current.fetchedAt.timeIntervalSince(previous.fetchedAt)
        guard elapsed.isFinite, elapsed > 0 else { return .nonMonotonic }
        guard elapsed <= Self.freshnessInterval, Self.isFresh(previous.fetchedAt, at: now) else { return .stale }
        return nil
    }

    private static func isFresh(_ fetchedAt: Date, at now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return now.timeIntervalSince1970.isFinite && fetchedAt.timeIntervalSince1970.isFinite
            && age.isFinite && age >= 0 && age <= freshnessInterval
    }

    private static func compare(_ previous: QuotaWindow, _ current: QuotaWindow, at now: Date) -> QuotaWindowUpdate.Change {
        guard let oldDuration = previous.durationMinutes, let newDuration = current.durationMinutes,
              oldDuration > 0, newDuration > 0 else { return .updated(reason: .dataUnavailable) }
        guard oldDuration == newDuration else { return .updated(reason: .durationChanged) }
        guard let oldReset = previous.resetsAt, let newReset = current.resetsAt,
              oldReset.timeIntervalSince1970.isFinite, newReset.timeIntervalSince1970.isFinite else {
            return .updated(reason: .dataUnavailable)
        }
        guard oldReset > now, newReset > now else { return .updated(reason: .resetPending) }
        guard oldReset == newReset else { return .updated(reason: .resetChanged) }
        guard let oldRemaining = previous.remainingPercent, let newRemaining = current.remainingPercent else {
            return .updated(reason: .dataUnavailable)
        }
        if newRemaining < oldRemaining {
            return .decreased(percentagePoints: oldRemaining - newRemaining)
        }
        if newRemaining > oldRemaining { return .updated(reason: .increased) }
        return .unchanged
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
