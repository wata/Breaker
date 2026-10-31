import Foundation
import Testing
@testable import Breaker

struct MonitoredItemTests {
    @Test func idIsPrefixedWithKind() {
        let item = MonitoredItem(
            key: "com.example.AudioPin",
            name: "AudioPin",
            status: .running,
            detail: .monitoredApp(.init(bundleID: "com.example.AudioPin", appURL: URL(filePath: "/Applications/AudioPin.app"), isRunning: true))
        )
        #expect(item.id == "monitoredApp:com.example.AudioPin")
        #expect(item.kind == .monitoredApp)
    }

    @Test func runningJobSummaryShowsPID() {
        let service = LaunchdServiceInfo(state: "running", pid: 812, runs: 1, lastExit: .never)
        let item = MonitoredItem(key: "com.example.job", name: "com.example.job", status: .running, detail: .launchdJob(.stub(service: service)))
        #expect(item.statusSummary == "Running (PID 812)")
    }

    /// 無効にしたジョブの見出しは「無効」だけ。定義ファイルの名前から分からない止め方だけを副行に出す
    @Test(arguments: [
        (true, false, String?.none),
        (false, true, "Via launchctl disable"),
        (true, true, nil),
    ])
    func disabledJobSummary(isDisabledFile: Bool, isDisabledLabel: Bool, note: String?) {
        let job = MonitoredItem.LaunchdJob.stub(isDisabledFile: isDisabledFile, isDisabledLabel: isDisabledLabel)
        let status = LaunchAgentSource.status(isDisabledFile: isDisabledFile, isDisabledLabel: isDisabledLabel, service: nil, keepAlive: false)
        let item = MonitoredItem(key: job.label, name: job.label, status: status, detail: .launchdJob(job))
        #expect(item.statusSummary == "Disabled")
        #expect(item.statusNote == note)
        // サイドバーは補足を除いた理由だけを出す
        #expect(item.status.reason == "Disabled")
    }

    /// ジョブ以外の止めた状態は、理由をそのまま見出しにして副行は出さない
    @Test func inactiveAppKeepsReason() {
        let item = MonitoredItem(
            key: "com.example.ClipboardKeeper",
            name: "ClipboardKeeper",
            status: .inactive(reason: "Not running"),
            detail: .monitoredApp(.init(bundleID: "com.example.ClipboardKeeper", appURL: URL(filePath: "/Applications/ClipboardKeeper.app"), isRunning: false))
        )
        #expect(item.statusSummary == "Not running")
        #expect(item.statusNote == nil)
    }

    /// Breaker が理由に添えた補足は見出しから副行へ回す。ツールチップと通知は補足を括弧で続けた全文
    @Test func warningMovesNoteOutOfSummary() {
        let item = MonitoredItem(
            key: "/Volumes/Share",
            name: "Share",
            status: FolderActionSource.missingFolderStatus,
            detail: .folderAction(.init(folderURL: URL(filePath: "/Volumes/Share"), scriptNames: [], isEnabled: true))
        )
        #expect(item.statusSummary == "Folder not found")
        #expect(item.statusNote == "it may not be mounted")
        #expect(item.status.reason == "Folder not found")
        #expect(item.status.fullReason == "Folder not found (it may not be mounted)")
    }

    /// 状態を読めなかった閲覧のみのジョブは、launchctl のエラー文を補足として副行に回す
    @Test func unknownMovesErrorToNote() {
        let job = MonitoredItem.LaunchdJob.stub()
        let item = MonitoredItem(key: job.label, name: job.label, status: .unknown(reason: "Can't read status", note: "boom"), detail: .launchdJob(job))
        #expect(item.statusSummary == "Can't read status")
        #expect(item.statusNote == "boom")
    }

    /// 外から受け取ったエラー文は、末尾が括弧書きでも見出しから分けない（osascript の「… (-1743)」など）
    @Test(arguments: [
        "Couldn't get folder actions from System Events (exit code 1): execution error: Not authorized to send Apple events to System Events. (-1743)",
        "launchctl print failed (boom)",
        "対象（未マウントの可能性）",
    ])
    func externalErrorKeepsParenthetical(reason: String) {
        let job = MonitoredItem.LaunchdJob.stub()
        let item = MonitoredItem(key: job.label, name: job.label, status: .warning(reason: reason), detail: .launchdJob(job))
        #expect(item.statusSummary == reason)
        #expect(item.statusNote == nil)
        #expect(item.status.reason == reason)
    }

    /// 失敗は括弧の中が原因そのものなので、見出しに残す
    @Test func failedKeepsParenthetical() {
        let job = MonitoredItem.LaunchdJob.stub()
        let item = MonitoredItem(key: job.label, name: job.label, status: .failed(reason: "Exit code 1"), detail: .launchdJob(job))
        #expect(item.statusSummary == "Failed (Exit code 1)")
        #expect(item.statusNote == nil)
    }

    /// パス・日時・ログの行は見出しに入れず副行に出し、見出しは「失敗（終了コード 1）」と同じ短い形にする
    @Test(arguments: [
        (HealthCheck.missedRunStatus(Date(timeIntervalSince1970: 1_800_000_000)), "Failed (Didn't run as scheduled)"),
        (ItemStatus.failed(reason: "Script not found", note: "~/dev/x.py"), "Failed (Script not found)"),
        (HealthCheck.logErrorStatus("Error: boom"), "Failed (Error in log)"),
    ])
    func failedMovesNoteOutOfSummary(status: ItemStatus, summary: String) {
        let job = MonitoredItem.LaunchdJob.stub()
        let item = MonitoredItem(key: job.label, name: job.label, status: status, detail: .launchdJob(job))
        #expect(item.statusSummary == summary)
        #expect(item.statusNote == status.note)
        #expect(item.statusNote != nil)
    }

    @Test func viewOnlyOnlyForLibraryJobs() {
        let agent = MonitoredItem.LaunchdJob.stub()
        let daemon = MonitoredItem.LaunchdJob.stub(origin: .daemon)
        #expect(!MonitoredItem(key: agent.label, name: agent.label, status: .ok, detail: .launchdJob(agent)).isViewOnly)
        #expect(MonitoredItem(key: daemon.label, name: daemon.label, status: .ok, detail: .launchdJob(daemon)).isViewOnly)
    }

    /// サイドバーの行のツールチップ。launchd ジョブは同じラベルのジョブを見分けられるよう種類を添える
    @Test func rowHelpPrefixesLaunchdJobOrigin() {
        let agent = MonitoredItem.LaunchdJob.stub()
        let daemon = MonitoredItem.LaunchdJob.stub(origin: .daemon)
        #expect(MonitoredItem(key: agent.label, name: agent.label, status: .failed(reason: "Exit code 1"), detail: .launchdJob(agent)).rowHelp == "User Agent · Exit code 1")
        #expect(MonitoredItem(key: daemon.label, name: daemon.label, status: .running, detail: .launchdJob(daemon)).rowHelp == "Daemon · Running")

        let app = MonitoredItem(
            key: "com.example.ClipboardKeeper",
            name: "ClipboardKeeper",
            status: .inactive(reason: "Not running"),
            detail: .monitoredApp(.init(bundleID: "com.example.ClipboardKeeper", appURL: URL(filePath: "/Applications/ClipboardKeeper.app"), isRunning: false))
        )
        #expect(app.rowHelp == "Not running")
    }

    /**
     サイドバーの2行目は1行だけ。理由があれば理由（要確認の節では種類を添える）、無ければ次回、次回が無ければ前回。
     予定で動かない種類の正常は出さない
     */
    @Test func rowDetailShowsOneFact() throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 10)))
        let lastRun = now.addingTimeInterval(-600)
        let english = Locale(identifier: "en_US")
        func detail(_ item: MonitoredItem, showsKind: Bool = false) -> String? {
            item.rowDetail(now: now, showsKind: showsKind, calendar: calendar, locale: english)
        }
        func job(_ status: ItemStatus, schedule: Schedule) -> MonitoredItem {
            let job = MonitoredItem.LaunchdJob.sample("job", schedule: schedule, lastRun: lastRun)
            return MonitoredItem(key: job.label, name: job.label, status: status, detail: .launchdJob(job))
        }
        let daily = Schedule(calendarEntries: [.init(minute: 0, hour: 9)])

        #expect(detail(job(.failed(reason: "Exit code 1"), schedule: daily)) == "Exit code 1")
        #expect(detail(job(.failed(reason: "Exit code 1"), schedule: daily), showsKind: true) == "launchd · Exit code 1")
        #expect(detail(job(.inactive(reason: "Disabled"), schedule: daily)) == "Disabled")
        let next = try #require(daily.nextRun(after: now, lastRun: lastRun))
        #expect(detail(job(.ok, schedule: daily)) == MonitoredItem.nextRunText(next, now: now, calendar: calendar, locale: english))
        #expect(detail(job(.ok, schedule: daily))?.hasPrefix("Next: Tomorrow") == true)
        #expect(detail(job(.ok, schedule: Schedule())) == "Last: 10 min. ago")

        let plugin = MonitoredItem(key: "p", name: "p", status: .ok, detail: .swiftBarPlugin(.init(fileURL: URL(filePath: "/tmp/p"), refreshInterval: nil)))
        #expect(detail(plugin) == nil)
        #expect(detail(MonitoredItem.sampleSourceFailure, showsKind: true) == "SwiftBar · Check failed")
    }

    /// 起動していないアプリは一時停止ではなく停止の記号。launchd の無効は一時停止のまま
    @Test func notRunningAppUsesStopSymbol() {
        let app = MonitoredItem(
            key: "a",
            name: "a",
            status: .inactive(reason: "Not running"),
            detail: .monitoredApp(.init(bundleID: "a", appURL: URL(filePath: "/Applications/a.app"), isRunning: false))
        )
        #expect(app.statusSystemImage == "stop.circle.fill")
        let job = MonitoredItem.LaunchdJob.stub()
        #expect(MonitoredItem(key: job.label, name: job.label, status: .inactive(reason: "Disabled"), detail: .launchdJob(job)).statusSystemImage == "pause.circle.fill")
    }

    @Test func sharedLogIsNamedLog() {
        let job = MonitoredItem.LaunchdJob.stub(standardOutPath: "/tmp/job.log", standardErrorPath: "/tmp/job.log")
        #expect(job.logFiles == [.init(kind: .combined, path: "/tmp/job.log")])
    }

    /// 失敗時にヘッダーの直後へ出すのは最後の1つなので、分かれているときは標準エラーが最後に来る
    @Test func separateLogsEndWithStandardError() {
        let job = MonitoredItem.LaunchdJob.stub(standardOutPath: "/tmp/job.log", standardErrorPath: "/tmp/job.err.log")
        #expect(job.logFiles.map(\.title) == ["Standard Output", "Standard Error"])
    }
}
