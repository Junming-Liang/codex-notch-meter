import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A transient capability snapshot, not a model identifier or telemetry record.
/// Rectangles are AppKit global points. visibleFrame is deliberately not an anchor.
public struct DisplaySnapshot: Equatable, Sendable {
    public var id: UInt32
    public var calibrationID: String?
    public var name: String
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var scale: Double
    public var builtIn: Bool
    public var online: Bool
    public var active: Bool
    public var asleep: Bool
    public var mirrored: Bool
    public var topInset: Double
    public var auxiliaryLeft: CGRect?
    public var auxiliaryRight: CGRect?
    public init(id: UInt32, calibrationID: String? = nil, name: String = "Display", frame: CGRect,
                visibleFrame: CGRect? = nil, scale: Double = 2, builtIn: Bool = true,
                online: Bool = true, active: Bool = true, asleep: Bool = false, mirrored: Bool = false,
                topInset: Double = 0, auxiliaryLeft: CGRect? = nil, auxiliaryRight: CGRect? = nil) {
        self.id = id; self.calibrationID = calibrationID; self.name = name; self.frame = frame
        self.visibleFrame = visibleFrame ?? frame; self.scale = scale; self.builtIn = builtIn
        self.online = online; self.active = active; self.asleep = asleep; self.mirrored = mirrored
        self.topInset = topInset; self.auxiliaryLeft = auxiliaryLeft; self.auxiliaryRight = auxiliaryRight
    }
}

public struct DisplayActivity: Equatable, Sendable {
    public var overlayEnabled = true
    public var systemSleeping = false
    public var displaysSleeping = false
    public var sessionActive = true
    public var applicationHidden = false
    public var terminating = false
    public init() {}
    public var permitsOverlay: Bool {
        overlayEnabled && !systemSleeping && !displaysSleeping && sessionActive && !applicationHidden && !terminating
    }
}

public enum DisplayFallback: String, Equatable, Sendable {
    case external, offline, inactive, asleep, mirrored, noCutout, invalidGeometry, insufficientRoom, duplicateID
}
public struct DisplayTarget: Equatable, Sendable {
    public let id: UInt32
    public let calibrationID: String?
    public let name: String
    public let geometry: IslandGeometry
    public let minimumAdjustment: Double
    public let maximumAdjustment: Double
}
public struct DisplayDecision: Equatable, Sendable {
    public let id: UInt32
    public let fallback: DisplayFallback?
}
public struct DisplayPlan: Equatable, Sendable {
    /// Eligible connected displays remain available for settings even with overlay disabled.
    public let eligible: [DisplayTarget]
    public let targets: [DisplayTarget]
    public let decisions: [DisplayDecision]
    public let activity: DisplayActivity
    public var shouldRecheck: Bool { activity.permitsOverlay }

    public static func make(snapshots: [DisplaySnapshot], activity: DisplayActivity,
                            calibrations: [String: Double] = [:]) -> DisplayPlan {
        let counts = Dictionary(grouping: snapshots, by: \.id).mapValues(\.count)
        let keys = Dictionary(grouping: snapshots.compactMap(\.calibrationID).filter { !$0.isEmpty && $0.count <= 64 }, by: { $0 }).mapValues(\.count)
        var eligible: [DisplayTarget] = [], decisions: [DisplayDecision] = []
        for display in snapshots.sorted(by: { $0.id < $1.id }) {
            let fallback: DisplayFallback?
            if counts[display.id] != 1 || display.id == 0 { fallback = .duplicateID }
            else if !display.builtIn { fallback = .external }
            else if !display.online { fallback = .offline }
            else if display.asleep { fallback = .asleep }
            else if !display.active { fallback = .inactive }
            else if display.mirrored { fallback = .mirrored }
            else if display.topInset == 0 && display.auxiliaryLeft == nil && display.auxiliaryRight == nil { fallback = .noCutout }
            else { fallback = nil }
            if let fallback { decisions.append(DisplayDecision(id: display.id, fallback: fallback)); continue }
            guard display.scale.isFinite, display.scale > 0,
                  let notch = NotchGeometry.calculate(screen: display.frame, topInset: display.topInset,
                      auxiliaryLeft: display.auxiliaryLeft, auxiliaryRight: display.auxiliaryRight) else {
                decisions.append(DisplayDecision(id: display.id, fallback: .invalidGeometry)); continue
            }
            // Ambiguous/missing identity never inherits another display's calibration.
            let key = display.calibrationID.flatMap { keys[$0] == 1 ? $0 : nil }
            let geometry = IslandGeometry(notch: notch, screen: display.frame, backingScale: display.scale,
                horizontalAdjustment: key.flatMap { calibrations[$0] } ?? 0)
            let container = display.frame.insetBy(dx: -0.001, dy: -0.001)
            guard container.contains(geometry.frame(progress: 0)), container.contains(geometry.frame(progress: 1)),
                  // The existing full-U renderer's fixed turns need this minimum envelope.
                  // These are drawing constraints, never inferred hardware/model dimensions.
                  geometry.contourFrame.width >= 24, geometry.contourFrame.height >= 12,
                  geometry.expandedSize.width >= 372,
                  geometry.expandedSize.height - notch.notch.height - 8 >= 280 else {
                decisions.append(DisplayDecision(id: display.id, fallback: .insufficientRoom)); continue
            }
            eligible.append(DisplayTarget(id: display.id, calibrationID: key, name: display.name, geometry: geometry,
                minimumAdjustment: IslandGeometry(notch: notch, screen: display.frame, backingScale: display.scale, horizontalAdjustment: -8).horizontalAdjustment,
                maximumAdjustment: IslandGeometry(notch: notch, screen: display.frame, backingScale: display.scale, horizontalAdjustment: 8).horizontalAdjustment))
            decisions.append(DisplayDecision(id: display.id, fallback: nil))
        }
        return DisplayPlan(eligible: eligible, targets: activity.permitsOverlay ? eligible : [], decisions: decisions, activity: activity)
    }
}
