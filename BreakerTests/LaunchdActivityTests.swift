import Foundation
import Testing
@testable import Breaker

struct LaunchdActivityTests {
    typealias Timeline = ItemDetailView.RunTimeline

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    /// 2026-10-30（金）10:00
    private let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 10))!

    @Test func dailyJobThatFailedYesterdayShowsTheWeek() throws {
        let job = MonitoredItem.LaunchdJob.sample(
            "daily",
            schedule: Schedule(calendarEntries: [.init(minute: 0, hour: 9)]),
            service: .init(state: "not running", pid: nil, runs: 3, lastExit: .code(1)),
            lastRun: now.addingTimeInterval(-25 * 3600)
        )
        let timeline = try #require(Timeline(job: job, status: .failed(reason: "Exit code 1"), nextRun: nextRun(job), now: now, calendar: Self.calendar))
        #expect(timeline.scale == .week)
        #expect(timeline.lastRun == job.lastRun)
        #expect(timeline.nextRun == now.addingTimeInterval(23 * 3600))
        #expect(timeline.lastRunStatus?.isFailed == true)
    }

    @Test func hourlyJobShowsSixHours() throws {
        let job = MonitoredItem.LaunchdJob.sample(
            "hourly",
            schedule: Schedule(calendarEntries: [.init(minute: 0)]),
            service: .init(state: "not running", pid: nil, runs: 3, lastExit: .code(0)),
            lastRun: now
        )
        let timeline = try #require(Timeline(job: job, status: .ok, nextRun: nextRun(job), now: now, calendar: Self.calendar))
        // 前回（10:00）と次回（11:00）が入り、予定が3つ以上並ぶ最も短い幅は6時間（8:30〜14:30）
        #expect(timeline.scale == .sixHours)
        #expect(timeline.runs.count == 5)
        #expect(timeline.nextRun.map(timeline.runs.contains) == false)
        #expect(timeline.ticks.count == 6)
    }

    /// 間隔に合わせて、予定が重ならずにいくつか並ぶ幅を選ぶ
    @Test func scaleFollowsTheInterval() throws {
        let cases: [(Schedule, Date?, Timeline.Scale)] = [
            (Schedule(calendarEntries: [.init()]), nil, .quarterHour),
            (Schedule(interval: 300), now.addingTimeInterval(-60), .hour),
            (Schedule(interval: 1800), now.addingTimeInterval(-600), .sixHours),
            (Schedule(calendarEntries: [.init(minute: 0, hour: 9)]), now.addingTimeInterval(-3600), .week),
            (Schedule(calendarEntries: [.init(minute: 0, hour: 11, day: 1)]), nil, .year),
        ]
        for (schedule, lastRun, scale) in cases {
            let job = MonitoredItem.LaunchdJob.sample("job", schedule: schedule, lastRun: lastRun)
            let timeline = try #require(Timeline(job: job, status: .ok, nextRun: nextRun(job), now: now, calendar: Self.calendar))
            #expect(timeline.scale == scale)
            #expect(timeline.runs.count < Timeline.runLimit)
        }
    }

    /// 動き続けている常駐ジョブは1日の幅に今までの帯を描き、常駐であることを説明に添える
    @Test func runningKeepAliveJobIsABandWithANote() throws {
        let agent = MonitoredItem.LaunchdJob.sample(
            "agent",
            schedule: Schedule(runAtLoad: true, keepAlive: true),
            service: .init(state: "running", pid: 812, runs: 1, lastExit: .never),
            lastRun: now.addingTimeInterval(-600)
        )
        let timeline = try #require(Timeline(job: agent, status: .running, nextRun: nextRun(agent), now: now, calendar: Self.calendar))
        #expect(timeline.scale == .day)
        #expect(timeline.isAlwaysRunning)
        #expect(timeline.runningSince == nil)
        #expect(timeline.lastRun == nil)
        #expect(timeline.note != nil)

        // 起動した時刻が分かれば、それが入る幅にして帯の始まりと説明に使う
        let started = MonitoredItem.LaunchdJob.sample(
            "agent",
            schedule: agent.schedule,
            service: agent.service,
            lastRun: agent.lastRun,
            processStartDate: now.addingTimeInterval(-3 * 86400)
        )
        let since = try #require(Timeline(job: started, status: .running, nextRun: nil, now: now, calendar: Self.calendar))
        // 3日前の起動は、過去を広く見せる1週間の幅（今は右端寄り）の左寄りに来る
        #expect(since.scale == .week)
        #expect(since.runningSince == started.processStartDate)
        #expect(since.fraction(of: now) > 0.8)
        #expect((0.05...0.6).contains(since.fraction(of: now.addingTimeInterval(-3 * 86400))))

        let justStarted = MonitoredItem.LaunchdJob.sample("agent", schedule: agent.schedule, service: agent.service, processStartDate: now.addingTimeInterval(-60))
        #expect(try #require(Timeline(job: justStarted, status: .running, nextRun: nil, now: now, calendar: Self.calendar)).scale == .quarterHour)

        let longAgo = MonitoredItem.LaunchdJob.sample("agent", schedule: agent.schedule, service: agent.service, processStartDate: now.addingTimeInterval(-400 * 86400))
        let year = try #require(Timeline(job: longAgo, status: .running, nextRun: nil, now: now, calendar: Self.calendar))
        #expect(year.scale == .year)
        // 範囲より前の起動は、何年前かを取り違えないよう年を付ける
        #expect(year.startLabel?.contains("2025") == true)
    }

    @Test func processStartDateOfThisProcess() throws {
        let start = try #require(ProcessStartDate.date(of: ProcessInfo.processInfo.processIdentifier))
        #expect(start <= .now)
        #expect(start > .now.addingTimeInterval(-3600))
        #expect(ProcessStartDate.date(of: 0x7fff_fff0) == nil)
    }

    /// 決まった予定の無いジョブ（ログイン時・ファイルの監視だけ）も線を出し、前回を載せて、何で走るかを説明に添える
    @Test func triggerOnlyJobShowsTheLastRunWithANote() throws {
        let watch = MonitoredItem.LaunchdJob.sample("watch", schedule: Schedule(runAtLoad: true, watchPaths: ["/etc/ssl/cert.pem"]))
        let neverRun = try #require(Timeline(job: watch, status: .ok, nextRun: nextRun(watch), now: now, calendar: Self.calendar))
        #expect(neverRun.scale == .day)
        #expect(neverRun.runs.isEmpty)
        // きっかけは右上の記号とスケジュールの行が言うので、凡例は添えない
        #expect(neverRun.note == nil)

        let ranLastWeek = MonitoredItem.LaunchdJob.sample("watch", schedule: watch.schedule, lastRun: now.addingTimeInterval(-3 * 86400))
        let timeline = try #require(Timeline(job: ranLastWeek, status: .ok, nextRun: nextRun(ranLastWeek), now: now, calendar: Self.calendar))
        // 3日前の前回は、「今」を右端寄りにした1週間の幅の左寄りに来る
        #expect(timeline.scale == .week)
        #expect(timeline.fraction(of: now) > 0.8)
        #expect(timeline.lastRun == ranLastWeek.lastRun)

        // 30時間前の前回は1日の幅に入らないので、1年まで飛ばずに1週間の幅にする
        let ranYesterday = MonitoredItem.LaunchdJob.sample("watch", schedule: watch.schedule, lastRun: now.addingTimeInterval(-30 * 3600))
        #expect(try #require(Timeline(job: ranYesterday, status: .ok, nextRun: nil, now: now, calendar: Self.calendar)).scale == .week)

        // 凡例を添えるのは常駐ジョブだけ
        let daily = MonitoredItem.LaunchdJob.sample("daily", schedule: Schedule(calendarEntries: [.init(minute: 0, hour: 9)]))
        #expect(try #require(Timeline(job: daily, status: .ok, nextRun: nextRun(daily), now: now, calendar: Self.calendar)).note == nil)
    }

    @Test func stoppedJobHasNoTimeline() {
        // 止めているジョブは走らないので、予定があっても線に描かない
        let stopped = MonitoredItem.LaunchdJob.sample("stopped", schedule: Schedule(interval: 1800), lastRun: now.addingTimeInterval(-600))
        #expect(Timeline(job: stopped, status: .inactive(reason: "Disabled"), nextRun: nil, now: now, calendar: Self.calendar) == nil)
    }

    /// 走らなかったことが理由の失敗は、走らなかった予定に輪を描き、前回の実行は終了コードどおり成功の印にする
    @Test func missedRunMarksTheSlotAndKeepsTheLastRunSucceeded() throws {
        let missed = Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 3, minute: 30))!
        let job = MonitoredItem.LaunchdJob.sample(
            "backup",
            schedule: Schedule(calendarEntries: [.init(minute: 30, hour: 3)]),
            service: .init(state: "not running", pid: nil, runs: 4, lastExit: .code(0)),
            lastRun: missed.addingTimeInterval(-86400 + 120)
        )
        let status = HealthCheck.missedRunStatus(missed)
        let timeline = try #require(Timeline(job: job, status: status, nextRun: nextRun(job), now: now, calendar: Self.calendar))
        #expect(timeline.missedRun == missed)
        #expect(!timeline.runs.contains(missed))
        #expect(timeline.lastRunStatus == .ok)

        let failedJob = MonitoredItem.LaunchdJob.sample(
            "backup",
            schedule: job.schedule,
            service: .init(state: "not running", pid: nil, runs: 4, lastExit: .code(1)),
            lastRun: job.lastRun
        )
        let exitFailure = ItemStatus.failed(reason: "Exit code 1")
        let failed = try #require(Timeline(job: failedJob, status: exitFailure, nextRun: nextRun(failedJob), now: now, calendar: Self.calendar))
        #expect(failed.missedRun == nil)
        #expect(failed.lastRunStatus == exitFailure)
    }

    @Test func serviceSummaryJoinsRunsAndLastExit() {
        typealias Section = ItemDetailView.LaunchdActivitySection
        let english = Locale(identifier: "en_US")
        let japanese = Locale(identifier: "ja_JP")
        #expect(Section.serviceSummary(of: .init(state: "not running", pid: nil, runs: 58, lastExit: .code(1)), locale: english) == "58 runs since loaded · Exit code 1")
        #expect(Section.serviceSummary(of: .init(state: "not running", pid: nil, runs: 58, lastExit: .code(1)), locale: japanese) == "58 回実行（読み込み後） · 終了コード 1")
        #expect(Section.serviceSummary(of: .init(state: "running", pid: 812, runs: 1, lastExit: .never), locale: english) == "1 run since loaded")
        // 0 は概要の「正常」と線の ✓ が言うので添えない
        #expect(Section.serviceSummary(of: .init(state: "not running", pid: nil, runs: 4, lastExit: .code(0)), locale: english) == "4 runs since loaded")
        #expect(Section.serviceSummary(of: .init(state: "not running", pid: nil, runs: 3, lastExit: .signal(SIGTERM)), locale: english) == "3 runs since loaded · Ended by SIGTERM")
        #expect(Section.signalName(30) == "30")
    }

    /// タイムラインに印で出した前回・次回は概要の文から外し、印にならない前回は文に残す
    @Test func headerLeavesOutDatesDrawnOnTheTimeline() {
        let drawn = MonitoredItem.LaunchdJob.sample(
            "hourly",
            schedule: Schedule(calendarEntries: [.init(minute: 0)]),
            service: .init(state: "not running", pid: nil, runs: 3, lastExit: .code(0)),
            lastRun: .now.addingTimeInterval(-600)
        )
        #expect(MonitoredItem(key: "a", name: "a", status: .ok, detail: .launchdJob(drawn)).headerRunSummary(now: .now) == nil)

        let stopped = MonitoredItem.LaunchdJob.sample("stopped", schedule: Schedule(interval: 1800), lastRun: .now.addingTimeInterval(-40 * 86400))
        let item = MonitoredItem(key: "b", name: "b", status: .inactive(reason: "Disabled"), detail: .launchdJob(stopped))
        #expect(item.headerRunSummary(now: .now) == item.runSummary(now: .now, lastRunStyle: .absolute))
        #expect(item.headerRunSummary(now: .now) != nil)
    }

    /// 夏時間に切り替わる日も、6時間ごとの目盛りは 0・6・12・18時の壁時計の区切りに置く
    @Test func ticksFollowTheWallClockAcrossDaylightSaving() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 22))!
        let ticks = Timeline.ticks(in: DateInterval(start: start, duration: 30 * 3600), scale: .day, calendar: calendar)
        #expect(ticks.map { calendar.component(.hour, from: $0) } == [0, 6, 12, 18, 0])

        let quarter = Timeline.ticks(in: DateInterval(start: start, duration: 15 * 60), scale: .quarterHour, calendar: calendar)
        #expect(quarter.map { calendar.component(.minute, from: $0) } == [5, 10, 15])
    }

    /// 前回より後の過ぎた予定は走っていないので、走った予定として塗らない
    @Test func onlyRunsUpToTheLastRunCountAsRan() throws {
        let job = MonitoredItem.LaunchdJob.sample(
            "hourly",
            schedule: Schedule(calendarEntries: [.init(minute: 0)]),
            lastRun: now.addingTimeInterval(-2 * 3600)
        )
        let timeline = try #require(Timeline(job: job, status: .ok, nextRun: nextRun(job), now: now, calendar: Self.calendar))
        let past = timeline.runs.filter { $0 < now }
        let ran = past.filter { run in timeline.ranUntil.map { run <= $0 } ?? false }
        #expect(ran.count < past.count)
        #expect(ran.allSatisfy { $0 <= now.addingTimeInterval(-2 * 3600) })
    }

    @Test func countdownRoundsDownAndNeverShowsZero() {
        let locale = Locale(identifier: "en_US")
        typealias Figure = ItemDetailView.DurationFigure
        #expect(Figure.durationText(from: now, to: now.addingTimeInterval(3 * 3600 + 12 * 60 + 59), locale: locale) == "3h 12m")
        #expect(Figure.durationText(from: now, to: now.addingTimeInterval(30), locale: locale) == "1m")
        #expect(Figure.durationText(from: now, to: now.addingTimeInterval(2 * 86400 + 5 * 3600), width: .wide, locale: locale) == "2 days, 5 hours")
    }

    private func nextRun(_ job: MonitoredItem.LaunchdJob) -> Date? {
        job.schedule.nextRun(after: now, lastRun: job.lastRun, calendar: Self.calendar)
    }
}
