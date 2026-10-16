import Foundation

/// One coalesced presentation awaiting an idle UI. No history or polling is added.
/// The original read/receipt timestamps survive suppression; waiting never renews
/// their freshness. Call invalidate for explicit continuity or preference changes.
public struct NoticeDeliveryQueue<Value: Identifiable> {
    private struct Entry {
        let value: Value
        let receivedAt: Date
        let fetchedAt: Date
        let resetsAt: Date?
    }
    private var entry: Entry?
    private var latestID: Value.ID?
    public init() {}
    public var isPending: Bool { entry != nil }

    public mutating func enqueue(_ value: Value, receivedAt: Date, fetchedAt: Date, resetsAt: Date?) {
        guard latestID != value.id else { return }
        latestID = value.id
        entry = Entry(value: value, receivedAt: receivedAt, fetchedAt: fetchedAt, resetsAt: resetsAt)
    }

    /// Inspect without consuming so a temporarily unavailable panel can retry.
    /// Even blocked entries expire; they cannot be revived by a later clock read.
    public mutating func candidate(at now: Date, blocked: Bool) -> Value? {
        guard let entry else { return nil }
        let receivedAge = now.timeIntervalSince(entry.receivedAt)
        let fetchedAge = now.timeIntervalSince(entry.fetchedAt)
        let dates = [now, entry.receivedAt, entry.fetchedAt]
        let fresh = dates.allSatisfy { $0.timeIntervalSince1970.isFinite }
            && receivedAge.isFinite && fetchedAge.isFinite
            && receivedAge >= 0 && receivedAge <= QuotaUpdateTracker.freshnessInterval
            && fetchedAge >= 0 && fetchedAge <= QuotaUpdateTracker.freshnessInterval
        let resetValid = entry.resetsAt.map { $0.timeIntervalSince1970.isFinite && $0 > now } ?? true
        guard fresh && resetValid else { self.entry = nil; return nil }
        return blocked ? nil : entry.value
    }

    public mutating func didDeliver() { entry = nil }
    public mutating func invalidate() { entry = nil }
}
