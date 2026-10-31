import Foundation
import Testing
@testable import Breaker

struct CronSourceTests {
    private static let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)

    // MARK: - コマンド

    @Test func readsRedirectsInOrder() {
        let command = CronCommand("~/bin/backup.sh >> ~/Library/Logs/backup.log 2>&1", home: Self.home)
        #expect(command.executable == "/Users/me/bin/backup.sh")
        #expect(command.firstPath == "~/bin/backup.sh")
        #expect(command.resolvedFirstPath == "/Users/me/bin/backup.sh")
        #expect(command.standardOutPath == "/Users/me/Library/Logs/backup.log")
        #expect(command.standardErrorPath == "/Users/me/Library/Logs/backup.log")
    }

    /// `2>&1` を先に書くと、標準エラーは元の標準出力（cron のメール）へ行く
    @Test func duplicateBeforeRedirectKeepsOriginalStandardOutput() {
        let command = CronCommand("/bin/date 2>&1 >> /tmp/date.log", home: Self.home)
        #expect(command.standardOutPath == "/tmp/date.log")
        #expect(command.standardErrorPath == nil)
    }

    @Test(arguments: [
        ("/bin/date > /tmp/out.log", "/tmp/out.log", nil),
        ("/bin/date >/tmp/out.log", "/tmp/out.log", nil),
        ("/bin/date 1>> /tmp/out.log", "/tmp/out.log", nil),
        ("/bin/date 2> /tmp/err.log", nil, "/tmp/err.log"),
        ("/bin/date 2>>/tmp/err.log", nil, "/tmp/err.log"),
        ("/bin/date &>> /tmp/both.log", "/tmp/both.log", "/tmp/both.log"),
        ("/bin/date &> /tmp/both.log", "/tmp/both.log", "/tmp/both.log"),
        ("/bin/date > /dev/null 2> logs/err.log", nil, "/Users/me/logs/err.log"),
        ("/bin/date > $LOG_DIR/out.log", nil, nil),
        ("/bin/date > $HOME/out.log 2> ${HOME}/err.log", "/Users/me/out.log", "/Users/me/err.log"),
        ("/bin/date > \"/tmp/my logs/out.log\"", "/tmp/my logs/out.log", nil),
        ("/bin/date > /dev/null 2>&1", nil, nil),
        ("/bin/date", nil, nil),
    ] as [(String, String?, String?)])
    func readsRedirectTargets(line: String, standardOut: String?, standardError: String?) {
        let command = CronCommand(line, home: Self.home)
        #expect(command.standardOutPath == standardOut)
        #expect(command.standardErrorPath == standardError)
    }

    /// `/bin/sh -c "…"` の文字列の中はシェルが後で解釈するので、リダイレクトもパスも見ない
    @Test func ignoresInsideCommandString() {
        let command = CronCommand("/bin/sh -c \"cd ~/dev/x && ./run.sh >> ~/x.log\"", home: Self.home)
        #expect(command.executable == "/bin/sh")
        #expect(command.firstPath == "/bin/sh")
        #expect(command.standardOutPath == nil)
    }

    /// `%` 以降は標準入力なので見ない。`\%` はただの `%`
    @Test func stopsAtUnescapedPercent() {
        #expect(CronCommand("~/bin/mail.sh > ~/m.log % body > /tmp/no.log", home: Self.home).standardOutPath == "/Users/me/m.log")
        #expect(CronCommand("date +\\%Y-\\%m > ~/d.log", home: Self.home).standardOutPath == "/Users/me/d.log")
        #expect(CronCommand.shellPart(of: "date +\\%Y % stdin") == "date +%Y ")
    }

    @Test(arguments: [
        ("FOO=1 /usr/bin/env python3 x.py", "/usr/bin/env"),
        ("echo hi", nil),
        ("$HOME/bin/x.sh", "/Users/me/bin/x.sh"),
        ("./run.sh", nil),
        ("\"/Users/me/My Scripts/run.sh\" --quiet", "/Users/me/My Scripts/run.sh"),
    ] as [(String, String?)])
    func findsExecutable(line: String, expected: String?) {
        #expect(CronCommand(line, home: Self.home).executable == expected)
    }

    @Test(arguments: [
        ("~/bin/backup.sh >> ~/backup.log", "backup.sh"),
        ("cd ~/dev/feeds && ./fetch.sh", "feeds"),
        ("/usr/bin/python3 ~/bin/job.py", "python3"),
        ("echo hello", "echo hello"),
        ("echo 0123456789012345678901234567890123456789XYZ", "echo 01234567890123456789012345678901234"),
    ])
    func makesName(line: String, expected: String) {
        #expect(CronSource.name(of: line, command: CronCommand(line, home: Self.home)) == expected)
    }

    // MARK: - crontab -l

    @Test func treatsNoCrontabAsEmpty() async throws {
        let shell = StubShell(output: ShellOutput(status: 1, stdout: "", stderr: "crontab: no crontab for me\n"))
        let items = try await CronSource(shell: shell, homeDirectory: Self.home).items()
        #expect(items.isEmpty)
        #expect(shell.calls == [.init(executable: "/usr/bin/crontab", arguments: ["-l"])])
    }

    @Test func throwsOnOtherFailure() async {
        let shell = StubShell(output: ShellOutput(status: 1, stdout: "", stderr: "crontab: permission denied\n"))
        await #expect(throws: CronError.self) {
            try await CronSource(shell: shell, homeDirectory: Self.home).items()
        }
    }

    // MARK: - 判定

    @Test func appliesChecksToEachLine() async throws {
        let home = try TemporaryDirectory()
        let path = home.url.path(percentEncoded: false).trimmingSuffix("/")
        let manager = FileManager.default
        try manager.createDirectory(at: home.url.appending(path: "bin"), withIntermediateDirectories: true)
        try manager.createDirectory(at: home.url.appending(path: "logs"), withIntermediateDirectories: true)
        let script = home.url.appending(path: "bin/ok.sh")
        try "#!/bin/sh\n# ノートを同期する\n".write(to: script, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        try "synced\n".write(to: home.url.appending(path: "logs/ok.log"), atomically: true, encoding: .utf8)
        try "Error: boom\n".write(to: home.url.appending(path: "logs/err.log"), atomically: true, encoding: .utf8)
        let stale = home.url.appending(path: "logs/stale.log")
        try "old\n".write(to: stale, atomically: true, encoding: .utf8)
        try manager.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3 * 86400)], ofItemAtPath: stale.path(percentEncoded: false))

        // 毎時の予定は正時の直後だと猶予の内なので、毎日の予定を6時間前にして、猶予（1日の1割）を確実に過ぎた状態にする
        let dailyHour = (Calendar.current.component(.hour, from: .now) + 18) % 24
        let crontab = """
            * * * * * ~/bin/ok.sh >> ~/logs/ok.log 2>&1
            0 * * * * ~/bin/missing.sh
            0 * * * * /bin/echo hi > ~/nofolder/x.log
            0 \(dailyHour) * * * /bin/echo stale >> ~/logs/stale.log
            0 * * * * /bin/echo never >> ~/logs/never.log
            * * * * * /bin/echo err >> ~/logs/err.log 2>&1
            0 \(dailyHour) * * * ~/bin/missing.sh >> ~/logs/stale.log
            garbage line
            @reboot /bin/echo up
            @reboot /bin/echo up
            """
        let bootTime = Date.now.addingTimeInterval(-30 * 86400)
        let shell = Self.shell(crontab: crontab, pmset: ShellOutput(status: 0, stdout: pmsetLine(bootTime, "Start"), stderr: ""))
        let awakeHistory = AwakeHistory(shell: shell)
        await awakeHistory.load(now: .now)
        let items = try await CronSource(shell: shell, homeDirectory: home.url, bootTime: { bootTime }, awakeHistory: awakeHistory).items()

        #expect(items.count == 10)
        #expect(items.allSatisfy { $0.kind == .cronJob && $0.isHomeItem })
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(items[0].name == "ok.sh")
        #expect(items[0].status == .ok)
        #expect(items[0].autoDescription == "ノートを同期する")
        // 起動するものやログのフォルダが無ければ走らないので、まだ走っていなくても失敗
        #expect(items[1].status == .failed(reason: "Executable not found", note: "~/bin/missing.sh"))
        #expect(items[2].status == .failed(reason: "Log folder not found", note: "~/nofolder"))
        #expect(items[3].status.reason == "Didn't run as scheduled")
        #expect(items[3].status.isFailed)
        // ログが一度も書かれていないなら走っていないとは言わない
        #expect(items[4].status == .ok)
        // ログにエラーがあればジョブの仕事は失敗している
        #expect(items[5].status == .failed(reason: "Error in log", note: "Error: boom"))
        // 静的チェックの問題があって走ってもいないなら、走っていないことより原因の分かる理由を出す
        #expect(items[6].status == .failed(reason: "Executable not found", note: "~/bin/missing.sh"))
        #expect(items[7].status == CronSource.unparsableStatus)
        #expect(items[7].name == "garbage line")
        #expect(items[8].status == .ok)
        #expect(items[8].id != items[9].id)

        guard case .cronJob(let job) = items[0].detail else {
            Issue.record("cron の行ではありません")
            return
        }
        #expect(job.standardOutPath == "\(path)/logs/ok.log")
        #expect(job.lastRun != nil)
        #expect(job.scriptURL(fileManager: manager)?.path(percentEncoded: false) == script.path(percentEncoded: false))
    }

    /// 前回の予定より後に Mac が起動したなら、走っていなくても異常にしない
    @Test func skipsMissedRunBeforeBoot() throws {
        let schedule = Schedule(calendarEntries: [.init(minute: 0)])
        // 毎時0分の予定に対し、猶予（15分）を過ぎた30分に固定する。Date.now だと0〜15分に走ったとき猶予内になって落ちる
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12, minute: 30)))
        let lastRun = now.addingTimeInterval(-3 * 86400)
        #expect(CronSource.missedRun(schedule: schedule, lastRun: lastRun, now: now, bootTime: now.addingTimeInterval(-60)) == nil)
        #expect(CronSource.missedRun(schedule: schedule, lastRun: lastRun, now: now, bootTime: nil) != nil)
        #expect(CronSource.missedRun(schedule: schedule, lastRun: nil, now: now, bootTime: nil) == nil)
        #expect(CronSource.missedRun(schedule: nil, lastRun: lastRun, now: now, bootTime: nil) == nil)
    }

    // MARK: - 予定の時刻に起きていたか

    private static func shell(crontab: String, pmset: ShellOutput) -> StubShell {
        StubShell { call in
            call.executable == "/usr/bin/pmset" ? pmset : ShellOutput(status: 0, stdout: crontab, stderr: "")
        }
    }

    /// 6時間前の毎日の予定に走っていない行（ログが3日前のまま）を、`pmset -g log` を前回の予定時刻から作って判定する
    private static func missedRunStatus(pmset: (Date) -> ShellOutput) async throws -> ItemStatus {
        let home = try TemporaryDirectory()
        try FileManager.default.createDirectory(at: home.url.appending(path: "logs"), withIntermediateDirectories: true)
        let log = home.url.appending(path: "logs/stale.log")
        try "old\n".write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3 * 86400)], ofItemAtPath: log.path(percentEncoded: false))
        let now = Date.now
        let hour = (Calendar.current.component(.hour, from: now) + 18) % 24
        let previous = try #require(Schedule(calendarEntries: [.init(minute: 0, hour: hour)]).previousRun(atOrBefore: now))
        let shell = Self.shell(crontab: "0 \(hour) * * * /bin/echo stale >> ~/logs/stale.log\n", pmset: pmset(previous))
        let awakeHistory = AwakeHistory(shell: shell)
        await awakeHistory.load(now: now)
        let bootTime = now.addingTimeInterval(-30 * 86400)
        let items = try await CronSource(shell: shell, homeDirectory: home.url, bootTime: { bootTime }, awakeHistory: awakeHistory).items()
        return try #require(items.first).status
    }

    private static func pmsetLog(_ lines: [(TimeInterval, String)], from previous: Date) -> ShellOutput {
        ShellOutput(status: 0, stdout: lines.map { pmsetLine(previous.addingTimeInterval($0 * 60), $1) }.joined(separator: "\n"), stderr: "")
    }

    @Test func reportsMissedRunWhenAwake() async throws {
        let status = try await Self.missedRunStatus { Self.pmsetLog([(-60, "Wake")], from: $0) }
        #expect(status.reason == "Didn't run as scheduled")
        #expect(status.isAbnormal)
        // 予定から最低限の時間だけ起きていれば、その後に眠っても出す
        let longEnough = try await Self.missedRunStatus { Self.pmsetLog([(-60, "Wake"), (11, "Sleep")], from: $0) }
        #expect(longEnough.isAbnormal)
    }

    @Test(arguments: [
        // 眠っていた
        [(-120, "Wake"), (-60, "Sleep"), (60, "Wake")],
        // DarkWake 中だった
        [(-120, "Wake"), (-60, "Sleep"), (-1, "DarkWake"), (1, "Sleep"), (60, "Wake")],
        // 起きていたが、予定から最低限の時間を待たずに眠った
        [(-60, "Wake"), (5, "Sleep")],
        // その時刻の記録が無い（ログが予定より後から始まる）
        [(60, "Start")],
    ] as [[(TimeInterval, String)]])
    func skipsMissedRunWhenNotAwake(lines: [(TimeInterval, String)]) async throws {
        let status = try await Self.missedRunStatus { Self.pmsetLog(lines, from: $0) }
        #expect(status == .ok)
    }

    @Test func skipsMissedRunWithoutPowerLog() async throws {
        let status = try await Self.missedRunStatus { _ in ShellOutput(status: 1, stdout: "", stderr: "pmset: error") }
        #expect(status == .ok)
    }

    /// 走っていない候補が無ければ `pmset` は走らせない
    @Test func readsPowerLogOnlyForCandidates() async throws {
        let home = try TemporaryDirectory()
        let shell = Self.shell(crontab: "0 * * * * /bin/echo hi >> ~/never.log\n", pmset: ShellOutput(status: 0, stdout: "", stderr: ""))
        _ = try await CronSource(shell: shell, homeDirectory: home.url, awakeHistory: AwakeHistory(shell: shell)).items()
        #expect(shell.calls == [.init(executable: "/usr/bin/crontab", arguments: ["-l"])])
    }

    // MARK: - 操作

    @Test func offersOnlyFileActions() throws {
        let directory = try TemporaryDirectory()
        let script = directory.url.appending(path: "job.sh")
        try Data().write(to: script)
        let job = MonitoredItem.CronJob(
            line: "0 3 * * * \(script.path(percentEncoded: false)) > /tmp/out.log 2> /tmp/err.log",
            expression: "0 3 * * *",
            command: "\(script.path(percentEncoded: false)) > /tmp/out.log 2> /tmp/err.log",
            schedule: Schedule(calendarEntries: [.init(minute: 0, hour: 3)]),
            isReboot: false,
            standardOutPath: "/tmp/out.log",
            standardErrorPath: "/tmp/err.log",
            lastRun: nil,
            firstPath: script.path(percentEncoded: false)
        )
        let item = MonitoredItem(key: job.line, name: "job.sh", status: .ok, detail: .cronJob(job))

        #expect(item.controlActions.map(\.title) == ["Run Now", "Stop"])
        #expect(item.controlActions.allSatisfy { !$0.isEnabled && $0.operation == .unavailable })
        #expect(item.secondaryControlActions.isEmpty)
        #expect(item.editActions.isEmpty)
        #expect(item.recoveryAction == nil)
        #expect(item.fileActions().map(\.title) == [
            "Open Standard Output Log",
            "Show Standard Output Log in Finder",
            "Open Standard Error Log",
            "Show Standard Error Log in Finder",
            "Open Script",
            "Show Script in Finder",
        ])
        #expect(item.errorLog?.path == "/tmp/err.log")
    }

    /// 最初のパスがフォルダや無いファイルなら、スクリプトの操作は出さない
    @Test func hidesScriptActionsWithoutFile() {
        let job = MonitoredItem.CronJob(
            line: "0 3 * * * cd /tmp && ./x.sh >> /tmp/x.log",
            expression: "0 3 * * *",
            command: "cd /tmp && ./x.sh >> /tmp/x.log",
            schedule: nil,
            isReboot: false,
            standardOutPath: "/tmp/x.log",
            standardErrorPath: nil,
            lastRun: nil,
            firstPath: "/tmp"
        )
        let item = MonitoredItem(key: job.line, name: "tmp", status: .ok, detail: .cronJob(job))
        #expect(item.fileActions().map(\.title) == ["Open Log", "Show Log in Finder"])
    }
}
