import Foundation
import Testing
@testable import Breaker

struct CrontabTests {
    /// コメント・空行・環境変数の行は項目にせず、解釈できない行は項目に残す
    @Test func parsesFixture() throws {
        let entries = Crontab.parse(try fixture("crontab-l"))
        #expect(entries.count == 10)

        let first = try #require(entries.first?.job)
        #expect(first.expression == "30 7 * * 1-5")
        #expect(first.command == "~/bin/sync-notes.sh >> ~/Library/Logs/sync-notes.log 2>&1")

        let feeds = try #require(fields(entries[1].job))
        #expect(feeds.minutes == [0, 15, 30, 45])
        #expect(feeds.hours == Set(9...18))
        #expect(feeds.weekdays == Set(1...5))
        #expect(feeds.isDayStar)

        #expect(entries[3].job?.expression == "@daily")
        #expect(entries[4].job?.timing == .reboot)
        #expect(entries[4].job?.command == "echo started")

        let halfYear = try #require(fields(entries[5].job))
        #expect(halfYear.months == [1, 7])
        #expect(halfYear.weekdays == [0])

        #expect(entries[6] == entries[7])
        #expect(entries[8].line == "61 * * * * ~/bin/broken.sh")
        #expect(entries[8].job == nil)
        #expect(entries[9].job == nil)
    }

    @Test(arguments: [
        ("1-10/3 * * * *", Set([1, 4, 7, 10])),
        ("0,30 * * * *", [0, 30]),
        ("*/20 * * * *", [0, 20, 40]),
    ] as [(String, Set<Int>)])
    func expandsMinutes(line: String, expected: Set<Int>) throws {
        let job = try #require(Crontab.parse("\(line) /bin/date").first?.job)
        #expect(fields(job)?.minutes == expected)
    }

    /// 曜日の 7 は日曜。名前は大文字小文字を問わず、範囲にも書ける
    @Test func normalizesWeekdayNames() throws {
        let job = try #require(Crontab.parse("0 0 * * 7,Mon-wed /bin/date").first?.job)
        #expect(fields(job)?.weekdays == [0, 1, 2, 3])
        #expect(fields(job)?.isWeekdayStar == false)
    }

    @Test(arguments: [
        "5/10 * * * * /bin/date",
        "60 * * * * /bin/date",
        "10-5 * * * * /bin/date",
        "*/0 * * * * /bin/date",
        "0 0 * foo * /bin/date",
        "0 0 32 * * /bin/date",
        "0 0 * * 8 /bin/date",
        "0 0 * * *",
        "0,,5 * * * * /bin/date",
        "@sometimes /bin/date",
        "@daily",
    ])
    func rejectsInvalidLines(line: String) {
        let entries = Crontab.parse(line)
        #expect(entries.count == 1)
        #expect(entries.first?.job == nil)
    }

    @Test func ignoresCommentsBlankLinesAndEnvironment() {
        let entries = Crontab.parse("\n  # comment\n\nHOME = '/Users/me'\n   \n")
        #expect(entries.isEmpty)
    }

    @Test(arguments: [
        ("@hourly", Schedule(calendarEntries: [.init(minute: 0)])),
        ("@daily", Schedule(calendarEntries: [.init(minute: 0, hour: 0)])),
        ("@midnight", Schedule(calendarEntries: [.init(minute: 0, hour: 0)])),
        ("@weekly", Schedule(calendarEntries: [.init(minute: 0, hour: 0, weekday: 0)])),
        ("@monthly", Schedule(calendarEntries: [.init(minute: 0, hour: 0, day: 1)])),
        ("@yearly", Schedule(calendarEntries: [.init(minute: 0, hour: 0, day: 1, month: 1)])),
        ("@annually", Schedule(calendarEntries: [.init(minute: 0, hour: 0, day: 1, month: 1)])),
        ("* * * * *", Schedule(calendarEntries: [.init()])),
    ])
    func convertsToSchedule(expression: String, expected: Schedule) throws {
        let job = try #require(Crontab.parse("\(expression) /bin/date").first?.job)
        #expect(fields(job)?.schedule == expected)
    }

    @Test func rebootHasNoSchedule() throws {
        let job = try #require(Crontab.parse("@REBOOT /bin/date").first?.job)
        #expect(job.timing == .reboot)
    }

    // MARK: - 次回の実行

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private func schedule(_ expression: String) throws -> Schedule? {
        let job = try #require(Crontab.parse("\(expression) /bin/date").first?.job)
        return fields(job)?.schedule
    }

    /// 2026-10-31 は土曜。平日 9:00 の次は月曜
    @Test func nextRunOnWeekdays() throws {
        let schedule = try #require(try schedule("0 9 * * 1-5"))
        #expect(schedule.nextRun(after: date(10, 31, 12), lastRun: nil, calendar: Self.calendar) == date(11, 2, 9))
        #expect(schedule.summaryLines == ["Weekdays at 9:00\u{202F}AM"])
    }

    /// 日と曜日の両方が `*` でないときは、どちらかに一致すれば動く（10日 または 金曜）
    @Test func dayAndWeekdayMatchEither() throws {
        let schedule = try #require(try schedule("0 0 10 * fri"))
        #expect(schedule.nextRun(after: date(11, 1), lastRun: nil, calendar: Self.calendar) == date(11, 6))
        #expect(schedule.nextRun(after: date(11, 6), lastRun: nil, calendar: Self.calendar) == date(11, 10))
    }

    /// 片方が `*` なら、もう片方だけで決まる
    @Test func starDayUsesWeekdayOnly() throws {
        let schedule = try #require(try schedule("0 0 * * 5"))
        #expect(schedule.nextRun(after: date(11, 6), lastRun: nil, calendar: Self.calendar) == date(11, 13))
    }

    /// 日を全部書くと、曜日とのどちらかに一致は毎日
    @Test func fullDayRangeWithWeekdayIsEveryDay() throws {
        #expect(try schedule("0 0 1-31 * 5") == Schedule(calendarEntries: [.init(minute: 0, hour: 0)]))
    }

    /// `*/2` で始まる日は「両方に一致」になり、CalendarEntry（どちらかに一致）では表せない
    @Test func starStepDayWithWeekdayIsNotRepresentable() throws {
        #expect(try schedule("0 0 */2 * 5") == nil)
        #expect(try schedule("0 0 */2 * *")?.calendarEntries.count == 16)
    }

    @Test func tooManyCombinationsAreNotConverted() throws {
        #expect(try schedule("0-58 0-22 1-30 * *") == nil)
    }

    // MARK: - 要約

    @Test func summarizesWithScheduleOrExpression() throws {
        #expect(cronJob("30 7 * * 1-5", schedule: try schedule("30 7 * * 1-5")).summaryLines == ["Weekdays at 7:30\u{202F}AM"])
        #expect(cronJob("0 9,18 * * *", schedule: try schedule("0 9,18 * * *")).summaryLines == ["Every day at 9:00\u{202F}AM", "Every day at 6:00\u{202F}PM"])
        // 要約が長すぎるものは式のまま
        #expect(cronJob("*/5 9-17 * * 1-5", schedule: try schedule("*/5 9-17 * * 1-5")).summaryLines == ["*/5 9-17 * * 1-5"])
        #expect(cronJob("0 0 */2 * 5", schedule: nil).summaryLines == ["0 0 */2 * 5"])
        #expect(cronJob("@reboot", schedule: nil, isReboot: true).summaryLines == ["When cron starts (@reboot)"])
    }

    private func cronJob(_ expression: String, schedule: Schedule?, isReboot: Bool = false) -> MonitoredItem.CronJob {
        MonitoredItem.CronJob(
            line: "\(expression) /bin/date",
            expression: expression,
            command: "/bin/date",
            schedule: schedule,
            isReboot: isReboot,
            standardOutPath: nil,
            standardErrorPath: nil,
            lastRun: nil,
            firstPath: nil
        )
    }

    private func fields(_ job: Crontab.Job?) -> Crontab.Fields? {
        guard case .fields(let fields) = job?.timing else {
            return nil
        }
        return fields
    }
}
