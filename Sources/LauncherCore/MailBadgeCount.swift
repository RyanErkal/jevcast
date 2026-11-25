import Foundation

/// The count on a sidebar row. Large counts are short, so the mailbox's name keeps its room:
/// 9,999 shows in full, 33,009 shows "33K", and 1,250,000 shows "1.2M". The exact count is in
/// the badge's tooltip and spoken value.
public enum MailBadgeCount {
    public static func text(_ count: Int, locale: Locale = .current) -> String {
        if count < 10_000 { return count.formatted(.number.locale(locale)) }
        if count < 1_000_000 { return "\(count / 1_000)K" }
        if count < 10_000_000 {
            // Rounded down, so the badge never says more than there is.
            let tenths = Double(count / 100_000) / 10
            return tenths.formatted(.number.precision(.fractionLength(0...1)).locale(locale)) + "M"
        }
        return "\(count / 1_000_000)M"
    }
}
