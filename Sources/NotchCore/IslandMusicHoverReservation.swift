import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A bounded hover reservation shared by native-event and polling recognizers.
/// Recognition keeps its independent trajectory history; changing input sources
/// must not renew ownership of an otherwise stationary pointer.
public struct IslandMusicHoverReservation: Equatable, Sendable {
    public static let maximumDuration: TimeInterval = 1.2
    public static let stationaryRadius: CGFloat = 3
    private var deadline: TimeInterval?
    public private(set) var stationaryAnchor: CGPoint?
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func resetDwell() { stationaryAnchor = nil }

    /// `now` is the delivery clock, not a queued native event's timestamp.
    /// An expired lease remains expired until a real exit or eligibility boundary.
    public mutating func reservesPointer(_ requested: Bool, insideCorridor: Bool,
                                        enabled: Bool, now: TimeInterval) -> Bool {
        // Eligibility and the narrow gesture corridor govern only the lease.
        // They must not erase hover's fixed anchor on every moving sample.
        guard enabled, insideCorridor, now.isFinite else { deadline = nil; return false }
        guard requested else { return false }
        if deadline == nil { deadline = now + Self.maximumDuration }
        return now < deadline!
    }

    /// Compare against a fixed anchor, not the previous sample: subpixel/hand
    /// jitter is harmless, but a slow cumulative traversal still resets dwell.
    public mutating func shouldResetDwell(at point: CGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { resetDwell(); return true }
        guard let anchor = stationaryAnchor else { stationaryAnchor = point; return false }
        guard hypot(point.x - anchor.x, point.y - anchor.y) > Self.stationaryRadius else { return false }
        stationaryAnchor = point
        return true
    }
}
