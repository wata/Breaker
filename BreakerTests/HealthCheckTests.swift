import Foundation
import Testing
@testable import Breaker

struct HealthCheckTests {
    typealias Entry = Schedule.CalendarEntry
    typealias Requirement = HealthCheck.Requirement

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private static let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)

    // MARK: - A. 走っていない検出

    /// 毎時0分は間隔の1割が6分なので、猶予は最低の15分。ちょうどはまだ異常にしない
    @Test func hourlyCalendarUsesMinimumGrace() {
        let hourly = Schedule(calendarEntries: [Entry(minute: 0)])
        let lastRun = date(10, 30, 8, 0)
        #expect(missedRun(hourly, lastRun: lastRun, now: date(10, 30, 9, 15)) == nil)
        #expect(missedRun(hourly, lastRun: lastRun, now: date(10, 30, 9, 15, 1)) == date(10, 30, 9, 0))
    }

    /// 毎日は間隔の1割（2時間24分）が猶予
    @Test func dailyCalendarUsesTenthOfInterval() {
        let daily = Schedule(calendarEntries: [Entry(minute: 0, hour: 9)])
        let lastRun = date(10, 29, 9, 1)
        #expect(missedRun(daily, lastRun: lastRun, now: date(10, 30, 11, 24)) == nil)
        #expect(missedRun(daily, lastRun: lastRun, now: date(10, 30, 11, 24, 1)) == date(10, 30, 9, 0))
    }

    @Test func calendarRunAfterScheduleIsNotMissed() {
        let daily = Schedule(calendarEntries: [Entry(minute: 0, hour: 9)])
        #expect(missedRun(daily, lastRun: date(10, 30, 9, 0, 3), now: date(10, 30, 18, 0)) == nil)
    }

    /// 電源が切れていた間の予定は launchd が走らせないので、起動が前回の予定より後なら数えない
    @Test func bootAfterScheduleIsNotMissed() {
        let daily = Schedule(calendarEntries: [Entry(minute: 0, hour: 9)])
        let lastRun = date(10, 29, 9, 1)
        let now = date(10, 30, 18, 0)
        #expect(missedRun(daily, lastRun: lastRun, now: now, bootTime: date(10, 30, 9, 30)) == nil)
        #expect(missedRun(daily, lastRun: lastRun, now: now, bootTime: date(10, 30, 9, 0)) == date(10, 30, 9, 0))
        #expect(missedRun(daily, lastRun: lastRun, now: now, bootTime: date(10, 30, 8, 0)) == date(10, 30, 9, 0))
    }

    /// ログの無いジョブも、見張りを始めてから実行を見ていなければ確かめる
    @Test func noLogIsCheckedFromWatchStart() {
        let daily = Schedule(calendarEntries: [Entry(minute: 0, hour: 9)])
        #expect(missedRun(daily, lastRun: nil, watchStart: date(10, 30, 8, 0), now: date(10, 30, 18, 0)) == date(10, 30, 9, 0))

        let schedule = Schedule(interval: 600)
        #expect(missedRun(schedule, lastRun: nil, watchStart: date(10, 30, 9, 0), now: date(10, 30, 9, 25)) == nil)
        #expect(missedRun(schedule, lastRun: nil, watchStart: date(10, 30, 9, 0), now: date(10, 30, 9, 25, 1)) == date(10, 30, 9, 10))
    }

    /// 見張りを始める前の予定は、ログが古くても走ったかどうか分からないので数えない
    @Test func scheduleBeforeWatchStartIsNotChecked() {
        let daily = Schedule(calendarEntries: [Entry(minute: 0, hour: 9)])
        let staleLog = date(10, 1, 9, 0)
        #expect(missedRun(daily, lastRun: staleLog, watchStart: date(10, 30, 9, 0), now: date(10, 30, 18, 0)) == nil)
        #expect(missedRun(daily, lastRun: staleLog, watchStart: date(10, 30, 10, 0), now: date(10, 30, 18, 0)) == nil)
        #expect(missedRun(daily, lastRun: staleLog, watchStart: date(10, 30, 10, 0), now: date(10, 31, 11, 25)) == date(10, 31, 9, 0))

        let schedule = Schedule(interval: 1800)
        let julyLog = date(7, 15, 9, 0)
        #expect(missedRun(schedule, lastRun: julyLog, watchStart: date(10, 30, 12, 0), now: date(10, 30, 12, 45)) == nil)
        #expect(missedRun(schedule, lastRun: julyLog, watchStart: date(10, 30, 12, 0), now: date(10, 30, 12, 45, 1)) == date(10, 30, 12, 30))
    }

    /// 正常なときにログへ何も書かないジョブ。ログが古くても、runs の変化で実行を見ていれば走っている
    @Test func observedRunCountsAsLastRun() {
        let schedule = Schedule(interval: 1800)
        let julyLog = date(7, 15, 9, 0)
        let observed = date(10, 30, 13, 30)
        let now = date(10, 30, 14, 0)
        let lastRun = [julyLog, observed].max()
        #expect(missedRun(schedule, lastRun: lastRun, watchStart: date(10, 30, 12, 0), now: now) == nil)
        #expect(missedRun(schedule, lastRun: julyLog, watchStart: date(10, 30, 12, 0), now: now) == date(10, 30, 12, 30))
    }

    @Test func noTimerIsNotChecked() {
        let schedule = Schedule(runAtLoad: true, keepAlive: true, watchPaths: ["/tmp"])
        #expect(missedRun(schedule, lastRun: date(10, 1, 0, 0), now: date(10, 30, 18, 0)) == nil)
    }

    /// 10分ごとは猶予が最低の15分: 最終実行 + 10分 + 15分 を過ぎたら異常
    @Test func shortIntervalUsesMinimumGrace() {
        let schedule = Schedule(interval: 600)
        let lastRun = date(10, 30, 9, 0)
        #expect(missedRun(schedule, lastRun: lastRun, now: date(10, 30, 9, 25)) == nil)
        #expect(missedRun(schedule, lastRun: lastRun, now: date(10, 30, 9, 25, 1)) == date(10, 30, 9, 10))
    }

    /// 10時間ごとは猶予が1割の1時間
    @Test func longIntervalUsesTenthOfInterval() {
        let schedule = Schedule(interval: 36000)
        let lastRun = date(10, 30, 0, 0)
        #expect(missedRun(schedule, lastRun: lastRun, now: date(10, 30, 11, 0)) == nil)
        #expect(missedRun(schedule, lastRun: lastRun, now: date(10, 30, 11, 0, 1)) == date(10, 30, 10, 0))
    }

    /// 最終実行より後に起動したら、StartInterval は起動時刻から数え直す
    @Test func intervalCountsFromBootAfterLastRun() {
        let schedule = Schedule(interval: 3600)
        let lastRun = date(10, 30, 9, 0)
        let now = date(10, 30, 11, 0)
        #expect(missedRun(schedule, lastRun: lastRun, now: now, bootTime: date(10, 30, 9, 50)) == nil)
        #expect(missedRun(schedule, lastRun: lastRun, now: now, bootTime: date(10, 30, 8, 0)) == date(10, 30, 10, 0))
        #expect(missedRun(schedule, lastRun: lastRun, now: date(10, 30, 11, 6), bootTime: date(10, 30, 9, 50)) == date(10, 30, 10, 50))
    }

    // MARK: - B. 静的チェック

    @Test(arguments: [
        (Requirement.Kind.executable, HealthCheck.FileState.missing, "Executable not found" as String?),
        (.executable, .file(isExecutable: false), "Can't be executed"),
        (.executable, .directory, "Can't be executed"),
        (.executable, .file(isExecutable: true), nil),
        (.interpreter, .missing, "Interpreter not found"),
        (.interpreter, .file(isExecutable: false), "Can't be executed"),
        (.interpreter, .file(isExecutable: true), nil),
        (.script, .missing, "Script not found"),
        (.script, .file(isExecutable: false), nil),
        (.script, .directory, nil),
        (.workingDirectory, .missing, "Working directory not found"),
        (.workingDirectory, .file(isExecutable: false), "Working directory not found"),
        (.workingDirectory, .directory, nil),
        (.logDirectory, .missing, "Log folder not found"),
        (.logDirectory, .directory, nil),
    ] as [(Requirement.Kind, HealthCheck.FileState, String?)])
    func fileFailure(kind: Requirement.Kind, state: HealthCheck.FileState, reason: String?) {
        let requirements = [Requirement(kind: kind, path: "/Users/me/bin/x")]
        // 在るべきパスが無ければ動けないので失敗。パスは補足に分ける
        #expect(HealthCheck.fileFailure(in: requirements, home: Self.home) { _ in state } == reason.map { .failed(reason: $0, note: "~/bin/x") })
        #expect(reason.map(HealthCheck.isFileProblem) ?? true)
    }

    @Test func fileProblemReportsFirstInOrderAndKeepsPathsOutsideHome() {
        let requirements = [
            Requirement(kind: .executable, path: "/usr/bin/python3"),
            Requirement(kind: .script, path: "/Users/meow/run.py"),
            Requirement(kind: .logDirectory, path: "/Users/me/Library/Logs"),
        ]
        let states: [String: HealthCheck.FileState] = ["/usr/bin/python3": .file(isExecutable: true)]
        let problem = HealthCheck.fileFailure(in: requirements, home: Self.home) { states[$0] ?? .missing }
        #expect(problem == .failed(reason: "Script not found", note: "/Users/meow/run.py"))
        #expect(!HealthCheck.isFileProblem("Exit code 1"))
    }

    @Test func fileStateReadsFileSystem() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(path: "run.sh")
        try Data().write(to: file)
        let path = file.path(percentEncoded: false)
        #expect(HealthCheck.fileState(atPath: path) == .file(isExecutable: false))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        #expect(HealthCheck.fileState(atPath: path) == .file(isExecutable: true))
        #expect(HealthCheck.fileState(atPath: directory.url.path(percentEncoded: false)) == .directory)
        #expect(HealthCheck.fileState(atPath: path + ".missing") == .missing)
    }

    @Test func requirementsOfInterpreterAndScript() {
        let requirements = LaunchAgentSource.requirements(
            program: nil,
            programArguments: ["/usr/bin/python3", "~/dev/scripts/report.py", "--quiet"],
            workingDirectory: "~/dev/scripts",
            logPaths: ["/Users/me/Library/Logs/report.log", "/Users/me/Library/Logs/report.err.log"],
            home: Self.home
        )
        #expect(requirements == [
            Requirement(kind: .executable, path: "/usr/bin/python3"),
            Requirement(kind: .script, path: "/Users/me/dev/scripts/report.py"),
            Requirement(kind: .workingDirectory, path: "/Users/me/dev/scripts"),
            Requirement(kind: .logDirectory, path: "/Users/me/Library/Logs"),
        ])
    }

    /// Program が先。ホームのスクリプトが起動するもの自身なら二重に確かめない
    @Test func requirementsOfHomeExecutable() {
        let requirements = LaunchAgentSource.requirements(
            program: "~/bin/tool",
            programArguments: ["tool", "--sync"],
            workingDirectory: nil,
            logPaths: [],
            home: Self.home
        )
        #expect(requirements == [Requirement(kind: .executable, path: "/Users/me/bin/tool")])
    }

    /// PATH を引かない名前と、`zsh -c` のコマンド文字列はパスとして確かめない
    @Test(arguments: [
        ["python3", "/Users/me/run.py"],
        ["/bin/zsh", "-l", "-c", "cd \"/Users/me/dev/vimeo\" && python3 refresh.py"],
        ["/bin/bash", "-lc", "/Users/me/run.sh --flag"],
    ])
    func requirementsSkipCommandNamesAndStrings(arguments: [String]) {
        let requirements = LaunchAgentSource.requirements(
            program: nil,
            programArguments: arguments,
            workingDirectory: nil,
            logPaths: [],
            home: Self.home
        )
        #expect(!requirements.contains { $0.kind == .executable && !$0.path.hasPrefix("/") })
        #expect(!requirements.contains { $0.path.contains(" ") })
    }

    // MARK: - C. ログのエラー

    /// 最後の 20 行だけを見る。21 行目より前のエラーは前の実行のものとして拾わない
    @Test func logErrorLooksAtLastTwentyLines() {
        let inside = (1...25).map { $0 == 6 ? "Error: token expired" : "step \($0)" }.joined(separator: "\n")
        let outside = (1...25).map { $0 == 5 ? "Error: token expired" : "step \($0)" }.joined(separator: "\n")
        #expect(HealthCheck.logError(in: [inside]) == "Error: token expired")
        #expect(HealthCheck.logError(in: [outside]) == nil)
    }

    @Test func logErrorPrefersFirstLog() {
        #expect(HealthCheck.logError(in: ["ok", "Error: stdout"]) == "Error: stdout")
        #expect(HealthCheck.logError(in: ["Error: stderr", "Error: stdout"]) == "Error: stderr")
        #expect(HealthCheck.logError(in: ["done", "all good"]) == nil)
        #expect(HealthCheck.logError(in: []) == nil)
    }

    @Test func logErrorTruncatesLongLine() throws {
        let line = "Error: " + String(repeating: "x", count: 200)
        let error = try #require(HealthCheck.logError(in: [line]))
        #expect(error.count == HealthCheck.maxLogErrorLength + 1)
        #expect(error.hasSuffix("…"))
    }

    /// 見張りの開始は、指定がなければどの予定よりも前（ずっと見張っていた）にする
    private func missedRun(_ schedule: Schedule, lastRun: Date?, watchStart: Date? = nil, now: Date, bootTime: Date? = nil) -> Date? {
        HealthCheck.missedRun(
            schedule: schedule,
            lastRun: lastRun,
            watchStart: watchStart ?? date(1, 1, 0, 0),
            now: now,
            bootTime: bootTime,
            calendar: Self.calendar
        )
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute, second: second))!
    }
}
