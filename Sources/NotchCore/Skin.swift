import Foundation

/// Raw values remain compatible with the original two-skin preference.
public enum MeterTheme: String, CaseIterable, Identifiable, Sendable {
    case standard, rainbow, aurora, sunset, ice

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .standard: return "经典薄荷"
        case .rainbow: return "流光彩虹"
        case .aurora: return "极光"
        case .sunset: return "日落暖金"
        case .ice: return "冰蓝"
        }
    }
    /// Selecting Rainbow opts into color motion; the separate motion switch can disable it.
    public var supportsMotion: Bool { self == .rainbow }
    public static func restored(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .standard
    }
}

public enum SkinMotionSpeed: String, CaseIterable, Identifiable, Sendable {
    case normal, slow

    public var id: String { rawValue }
    public var title: String { self == .normal ? "标准" : "缓慢" }
    public var cycleDuration: TimeInterval { self == .normal ? 8 : 12 }
    public static func restored(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .normal
    }
}

/// One shared color clock is scheduled only while a visible owned surface can animate.
/// Application activation is deliberately absent: a menu-bar overlay remains visible
/// when another app is frontmost. Session inactivity is a separate system condition.
public struct SkinMotionPolicy: Equatable, Sendable {
    public static let maximumFramesPerSecond: Double = 15
    public static let frameInterval: TimeInterval = 1 / maximumFramesPerSecond

    public var theme: MeterTheme
    public var motionEnabled: Bool
    public var reduceMotion: Bool
    public var lowPowerMode: Bool
    public var asleep: Bool
    public var overlayEnabled: Bool
    public var hasVisibleOwnedSurface: Bool
    public var sessionActive: Bool

    public init(theme: MeterTheme = .standard, motionEnabled: Bool = true,
                reduceMotion: Bool = false, lowPowerMode: Bool = false,
                asleep: Bool = false, overlayEnabled: Bool = true,
                hasVisibleOwnedSurface: Bool = false, sessionActive: Bool = true) {
        self.theme = theme
        self.motionEnabled = motionEnabled
        self.reduceMotion = reduceMotion
        self.lowPowerMode = lowPowerMode
        self.asleep = asleep
        self.overlayEnabled = overlayEnabled
        self.hasVisibleOwnedSurface = hasVisibleOwnedSurface
        self.sessionActive = sessionActive
    }

    public var isRunning: Bool {
        theme.supportsMotion && motionEnabled && !reduceMotion && !lowPowerMode &&
            !asleep && overlayEnabled && hasVisibleOwnedSurface && sessionActive
    }
}

/// Pure elapsed-time color phase, independent of frame cadence and quota progress.
/// Supply monotonic uptime; call update at every pause/resume transition even when
/// the render timer is stopped. The previous running state owns the elapsed interval.
/// Before changing speed, update at the transition time using the previous speed.
public struct SkinPhaseClock: Equatable, Sendable {
    public var speed: SkinMotionSpeed
    public private(set) var phase: Double = 0
    public private(set) var isRunning = false
    private var lastTime: TimeInterval?

    public init(speed: SkinMotionSpeed = .normal) { self.speed = speed }

    @discardableResult
    public mutating func update(now: TimeInterval, running: Bool) -> Double {
        guard now.isFinite, now >= 0 else {
            // An invalid sample breaks continuity. Reanchor at the next valid time
            // instead of counting an interval whose lifecycle state is unknown.
            lastTime = nil
            isRunning = running
            return phase
        }
        if let lastTime, now >= lastTime, isRunning {
            // Reduce before division/addition so even enormous finite jumps stay bounded.
            let elapsed = (now - lastTime).truncatingRemainder(dividingBy: speed.cycleDuration)
            phase = (phase + elapsed / speed.cycleDuration).truncatingRemainder(dividingBy: 1)
        }
        // A backwards sample preserves phase and establishes a new baseline.
        lastTime = now
        isRunning = running
        return phase
    }
}

public extension QuotaBucket {
    /// Keep all windows in the bucket. This chooses only which one the single contour
    /// represents; unknown durations sort last and input order breaks equal-duration ties.
    func primaryWindow(preferredID: String? = nil) -> QuotaWindow? {
        if let preferredID, let preferred = windows.first(where: { $0.id == preferredID }) {
            return preferred
        }
        var selected: QuotaWindow?
        for window in windows {
            guard let current = selected else { selected = window; continue }
            if let duration = window.durationMinutes,
               current.durationMinutes.map({ duration < $0 }) ?? true {
                selected = window
            }
        }
        return selected
    }
}
