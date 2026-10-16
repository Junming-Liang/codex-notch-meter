import Foundation

/// Time a quota notice stays fully expanded, excluding opening and closing animation.
/// Persist rawValue in the app layer; keep these storage strings stable.
public enum NoticeDuration: String, CaseIterable, Identifiable, Sendable {
    case short = "short"
    case standard = "standard"
    case long = "long"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .short: return "短"
        case .standard: return "标准"
        case .long: return "长"
        }
    }

    public var seconds: TimeInterval {
        switch self {
        case .short: return 2
        case .standard: return 4
        case .long: return 6
        }
    }

    public static func restored(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .standard
    }
}
