import Foundation

/// Local dates as the tools read and write them: 2026-10-21, and to the minute 2026-10-21T09:30.
package enum Stamp {
    static func format(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.isLenient = false
        return formatter
    }

    package static let dayFormat = format("yyyy-MM-dd")
    package static let minuteFormat = format("yyyy-MM-dd'T'HH:mm")

    package static func minute(_ date: Date) -> String { minuteFormat.string(from: date) }
    package static func day(_ date: Date) -> String { dayFormat.string(from: date) }
}
