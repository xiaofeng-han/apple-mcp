import Foundation

/// What Journal's Insights show, worked out from the entries' dates: days journaled and
/// streaks, daily and weekly (Journal counts either, as the user chooses).
struct Insights: Equatable {
    var entries = 0
    var daysJournaled = 0
    var daysThisYear = 0
    var entriesThisYear = 0
    var currentDailyStreak = 0
    var longestDailyStreak = 0
    var currentWeeklyStreak = 0
    var longestWeeklyStreak = 0
    var first: Date?
    var last: Date?

    /// A streak still counts until the day (or week) after its last one has passed.
    init(dates: [Date], now: Date = Date(), calendar: Calendar = .current) {
        guard !dates.isEmpty else { return }
        entries = dates.count
        first = dates.min()
        last = dates.max()
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        daysJournaled = days.count
        let year = calendar.component(.year, from: now)
        daysThisYear = days.filter { calendar.component(.year, from: $0) == year }.count
        entriesThisYear = dates.filter { calendar.component(.year, from: $0) == year }.count

        let today = calendar.startOfDay(for: now)
        (currentDailyStreak, longestDailyStreak) = Self.streaks(Set(days.map { Self.dayNumber($0, calendar) }), current: Self.dayNumber(today, calendar))
        let weeks = Set(days.map { Self.weekNumber($0, calendar) })
        (currentWeeklyStreak, longestWeeklyStreak) = Self.streaks(weeks, current: Self.weekNumber(today, calendar))
    }

    /// Days since a fixed day, so consecutive days are consecutive numbers.
    static func dayNumber(_ day: Date, _ calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: Date(timeIntervalSinceReferenceDate: 0), to: day).day ?? 0
    }

    static func weekNumber(_ day: Date, _ calendar: Calendar) -> Int {
        let start = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
        return dayNumber(start, calendar) / 7
    }

    /// The run that ends at `current` or the one before it, and the longest run.
    static func streaks(_ numbers: Set<Int>, current: Int) -> (current: Int, longest: Int) {
        var longest = 0
        for number in numbers where !numbers.contains(number - 1) {
            var length = 1
            while numbers.contains(number + length) { length += 1 }
            longest = max(longest, length)
        }
        var end = numbers.contains(current) ? current : current - 1
        var run = 0
        while numbers.contains(end) {
            run += 1
            end -= 1
        }
        return (run, longest)
    }
}
