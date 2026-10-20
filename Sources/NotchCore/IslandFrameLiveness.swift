import Foundation

/// Delivery-clock watchdog for a single, short-lived geometry transition.
/// Display-link target timestamps may be in the future and must not renew this lease.
public struct IslandFrameLiveness: Equatable, Sendable {
    public enum Decision: Equatable, Sendable { case wait, suspend, recover, stopped }
    public static let maximumSilence: TimeInterval = 0.3
    private var lastDelivery: TimeInterval
    private var active = true
    public private(set) var recovered = false
    public init(now: TimeInterval) { lastDelivery = now }
    public mutating func delivered(at now: TimeInterval) {
        guard active, now.isFinite, now >= lastDelivery else { return }
        lastDelivery = now
    }
    public mutating func probe(at now: TimeInterval, presentationAllowed: Bool) -> Decision {
        guard active else { return .stopped }
        guard !recovered, presentationAllowed else { return .suspend }
        guard now.isFinite, lastDelivery.isFinite, now >= lastDelivery,
              now - lastDelivery >= Self.maximumSilence else { return .wait }
        recovered = true
        return .recover
    }
    public mutating func stop() { active = false }
}
