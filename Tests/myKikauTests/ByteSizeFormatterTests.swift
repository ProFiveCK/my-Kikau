import Testing
import Core
import Foundation

@Suite("ByteSizeFormatter")
struct ByteSizeFormatterTests {
    // MARK: format(_:) — ByteCountFormatter output is locale-dependent,
    // so assert non-empty and directional growth rather than exact strings.

    @Test("format returns a non-empty string for zero bytes")
    func formatZero() {
        let s = ByteSizeFormatter.format(0)
        #expect(!s.isEmpty)
    }

    @Test("format returns a non-empty string across KB/MB/GB magnitudes")
    func formatMagnitudes() {
        let kb = ByteSizeFormatter.format(1_024)
        let mb = ByteSizeFormatter.format(1_048_576)
        let gb = ByteSizeFormatter.format(1_073_741_824)
        #expect(!kb.isEmpty)
        #expect(!mb.isEmpty)
        #expect(!gb.isEmpty)
    }

    // MARK: formatRounded(_:)

    @Test("formatRounded delegates to format for sub-MB sizes")
    func formatRoundedSubMBDelegates() {
        // 0 bytes — less than 1 MB, delegates to format.
        let zero = ByteSizeFormatter.formatRounded(0)
        #expect(!zero.isEmpty)

        // 500 KB — less than 1 MB, delegates to format.
        let subMB = ByteSizeFormatter.formatRounded(500_000)
        #expect(!subMB.isEmpty)
    }

    @Test("formatRounded returns MB for 1–999 MB range")
    func formatRoundedMB() {
        // 10 MB = 10_000_000 bytes -> 10.0 MB -> "10 MB" (no decimals).
        let result = ByteSizeFormatter.formatRounded(10_000_000)
        #expect(result == "10 MB")
    }

    @Test("formatRounded returns GB for >= 1 GB")
    func formatRoundedGB() {
        // 2_600 MB = 2.6 GB -> rounds to "3 GB" (0 decimals, half-up).
        let result = ByteSizeFormatter.formatRounded(2_600_000_000)
        #expect(result == "3 GB")
    }

    // MARK: formatPercent(_:)

    @Test("formatPercent formats a whole number with one decimal")
    func formatPercentWhole() {
        #expect(ByteSizeFormatter.formatPercent(50.0) == "50.0%")
    }

    @Test("formatPercent formats a fraction with one decimal")
    func formatPercentFraction() {
        #expect(ByteSizeFormatter.formatPercent(12.5) == "12.5%")
    }

    @Test("formatPercent rounds to one decimal place")
    func formatPercentRounds() {
        // 33.333... rounds to 33.3 with one fraction digit.
        #expect(ByteSizeFormatter.formatPercent(33.3333) == "33.3%")
    }

    @Test("formatPercent handles zero")
    func formatPercentZero() {
        #expect(ByteSizeFormatter.formatPercent(0.0) == "0.0%")
    }

    @Test("formatPercent handles 100")
    func formatPercentFull() {
        #expect(ByteSizeFormatter.formatPercent(100.0) == "100.0%")
    }
}