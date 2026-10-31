import Foundation
import Testing
@testable import Breaker

struct ScheduleTests {
    typealias Entry = Schedule.CalendarEntry

    /// 夏時間のないタイムゾーンに固定し、実行環境に左右されないようにする
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    /// 2026-10-30 は金曜日
    private let friday = date(2026, 10, 30, 10, 0)

    @Test func weekdaysAtNineSkipToMonday() {
        let schedule = Schedule(calendarEntries: (1...5).map { Entry(minute: 0, hour: 9, weekday: $0) })
        #expect(nextRun(schedule, after: friday) == date(2026, 11, 2, 9, 0))
        #expect(nextRun(schedule, after: date(2026, 10, 29, 8, 0)) == date(2026, 10, 29, 9, 0))
    }

    @Test func monthlyFirstDay() {
        let schedule = Schedule(calendarEntries: [Entry(minute: 0, hour: 11, day: 1)])
        #expect(nextRun(schedule, after: friday) == date(2026, 11, 1, 11, 0))
        #expect(nextRun(schedule, after: date(2026, 11, 1, 11, 0)) == date(2026, 12, 1, 11, 0))
    }

    @Test func daily() {
        let schedule = Schedule(calendarEntries: [Entry(minute: 30, hour: 3)])
        #expect(nextRun(schedule, after: friday) == date(2026, 10, 31, 3, 30))
    }

    @Test func wildcardMinuteRunsEveryMinuteOfTheHour() {
        let schedule = Schedule(calendarEntries: [Entry(hour: 9)])
        #expect(nextRun(schedule, after: date(2026, 10, 30, 9, 30, 20)) == date(2026, 10, 30, 9, 31))
        #expect(nextRun(schedule, after: friday) == date(2026, 10, 31, 9, 0))
    }

    @Test func wildcardHourRunsEveryHour() {
        let schedule = Schedule(calendarEntries: [Entry(minute: 15)])
        #expect(nextRun(schedule, after: date(2026, 10, 30, 10, 20)) == date(2026, 10, 30, 11, 15))
    }

    @Test func emptyEntryRunsEveryMinute() {
        let schedule = Schedule(calendarEntries: [Entry()])
        #expect(nextRun(schedule, after: date(2026, 10, 30, 10, 0, 1)) == date(2026, 10, 30, 10, 1))
    }

    @Test(arguments: [0, 7])
    func sundayAcceptsZeroAndSeven(weekday: Int) {
        let schedule = Schedule(calendarEntries: [Entry(minute: 0, hour: 8, weekday: weekday)])
        #expect(nextRun(schedule, after: friday) == date(2026, 11, 1, 8, 0))
    }

    @Test func dayAndWeekdayMatchEither() {
        let schedule = Schedule(calendarEntries: [Entry(minute: 0, hour: 0, day: 15, weekday: 1)])
        #expect(nextRun(schedule, after: friday) == date(2026, 11, 2, 0, 0))
    }

    @Test func leapDayIsFoundYearsAhead() {
        let schedule = Schedule(calendarEntries: [Entry(minute: 0, hour: 0, day: 29, month: 2)])
        #expect(nextRun(schedule, after: friday) == date(2028, 2, 29, 0, 0))
    }

    @Test func previousRunLooksBackIncludingTheSameMinute() {
        let weekdays = Schedule(calendarEntries: (1...5).map { Entry(minute: 0, hour: 9, weekday: $0) })
        #expect(weekdays.previousRun(atOrBefore: date(2026, 11, 2, 8, 0), calendar: Self.calendar) == date(2026, 10, 30, 9, 0))
        #expect(weekdays.previousRun(atOrBefore: date(2026, 11, 2, 9, 0), calendar: Self.calendar) == date(2026, 11, 2, 9, 0))

        let hourly = Schedule(calendarEntries: [Entry(minute: 15)])
        #expect(hourly.previousRun(atOrBefore: date(2026, 10, 30, 10, 14), calendar: Self.calendar) == date(2026, 10, 30, 9, 15))

        let monthly = Schedule(calendarEntries: [Entry(minute: 0, hour: 11, day: 1), Entry(minute: 0, hour: 0, day: 15)])
        #expect(monthly.previousRun(atOrBefore: friday, calendar: Self.calendar) == date(2026, 10, 15, 0, 0))

        #expect(Schedule(interval: 1800).previousRun(atOrBefore: friday, calendar: Self.calendar) == nil)
    }

    @Test func startIntervalCountsFromLastRun() {
        let schedule = Schedule(interval: 1800)
        let lastRun = date(2026, 10, 30, 10, 0)
        #expect(schedule.nextRun(after: date(2026, 10, 30, 10, 45), lastRun: lastRun, calendar: Self.calendar) == date(2026, 10, 30, 11, 0))
        #expect(schedule.nextRun(after: date(2026, 10, 30, 10, 30), lastRun: lastRun, calendar: Self.calendar) == date(2026, 10, 30, 11, 0))
        #expect(schedule.nextRun(after: date(2026, 10, 30, 9, 0), lastRun: lastRun, calendar: Self.calendar) == date(2026, 10, 30, 10, 30))
        #expect(schedule.nextRun(after: friday, lastRun: nil, calendar: Self.calendar) == nil)
    }

    @Test func picksEarliestOfCalendarAndInterval() {
        let schedule = Schedule(calendarEntries: [Entry(minute: 0, hour: 12)], interval: 3600)
        #expect(schedule.nextRun(after: friday, lastRun: friday, calendar: Self.calendar) == date(2026, 10, 30, 11, 0))
    }

    @Test func noTriggerHasNoNextRun() {
        let schedule = Schedule(runAtLoad: true, keepAlive: true)
        #expect(schedule.nextRun(after: friday, lastRun: friday, calendar: Self.calendar) == nil)
    }

    @Test func readsPlistDictionary() {
        let single = Schedule(plist: [
            "StartCalendarInterval": ["Hour": 11, "Minute": 0, "Day": 1],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "WatchPaths": ["/etc/ssl/cert.pem"],
        ])
        #expect(single.calendarEntries == [Entry(minute: 0, hour: 11, day: 1)])
        #expect(single.runAtLoad)
        #expect(!single.keepAlive)
        #expect(single.watchPaths == ["/etc/ssl/cert.pem"])

        let multiple = Schedule(plist: [
            "StartCalendarInterval": [["Weekday": 1, "Hour": 9], ["Weekday": 7]],
            "StartInterval": 1800,
            "KeepAlive": true,
        ])
        #expect(multiple.calendarEntries == [Entry(hour: 9, weekday: 1), Entry(weekday: 7)])
        #expect(multiple.interval == 1800)
        #expect(multiple.keepAlive)
    }

    private func nextRun(_ schedule: Schedule, after date: Date) -> Date? {
        schedule.nextRun(after: date, lastRun: nil, calendar: Self.calendar)
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Self.date(year, month, day, hour, minute, second)
    }
}
