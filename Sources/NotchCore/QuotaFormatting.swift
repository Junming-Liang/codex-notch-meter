import Foundation

public enum QuotaFormatting {
    public static func percent(_ value: Double) -> String {
        guard value.isFinite, (0...100).contains(value) else { return "—" }
        return decimal(value) + "%"
    }
    public static func points(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        return value < 0.01 ? "<0.01" : decimal(value)
    }
    private static func decimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}
