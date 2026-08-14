import Foundation

/// Formats byte counts into human-readable strings (e.g. "12.3 GB").
public enum ByteSizeFormatter {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        f.includesUnit = true
        f.allowsNonnumericFormatting = false
        return f
    }()

    /// Formats a byte count with one decimal place.
    public static func format(_ bytes: Int64) -> String {
 formatter.string(fromByteCount: bytes) }

    /// Formats a byte count with no decimal places (rounded).
    public static func formatRounded(_ bytes: Int64) -> String {
        let f = NumberFormatter()
        f.maximumFractionDigits = 0
        let mb = Double(bytes) / 1_000_000
        if mb < 1 { return format(bytes) }
        let gb = mb / 1000
        if gb < 1 {
            return (f.string(from: NSNumber(value: mb)) ?? "\(mb)") + " MB"
        }
        return (f.string(from: NSNumber(value: gb)) ?? "\(gb)") + " GB"
    }

    /// Formats a percentage value.
    public static func formatPercent(_ value: Double) -> String {
        let f = NumberFormatter()
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 1
        return (f.string(from: NSNumber(value: value)) ?? "\(value)") + "%"
    }
}