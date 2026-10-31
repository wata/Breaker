import Foundation
import Testing
@testable import Breaker

struct ItemActionTests {
    private static let loaded = LaunchdServiceInfo(state: "not running", pid: nil, runs: 1, lastExit: .code(0))
    private static let running = LaunchdServiceInfo(state: "running", pid: 42, runs: 1, lastExit: .never)

    @Test func loadedJobCanRunNowAndStop() {
        let job = MonitoredItem.LaunchdJob.stub(service: Self.loaded)
        #expect(job.controlActions.map(\.title) == ["Run Now", "Stop"])
        #expect(job.controlActions.map(\.isEnabled) == [true, true])
        #expect(!job.reloadAction.isEnabled)
    }

    @Test func runningJobCannotRunNow() {
        let actions = MonitoredItem.LaunchdJob.stub(service: Self.running).controlActions
        #expect(actions.map(\.title) == ["Run Now", "Stop"])
        #expect(actions.map(\.isEnabled) == [false, true])
    }

    /// 未ロードでも無効化はされていないので、読み込み直すか、無効にして止めるかを選べる。ボタンの組は読み込み済みと変えない
    @Test func unloadedJobOffersReloadAndStop() {
        let job = MonitoredItem.LaunchdJob.stub()
        #expect(job.controlActions.map(\.title) == ["Run Now", "Stop"])
        #expect(job.controlActions.map(\.isEnabled) == [false, true])
        #expect(job.reloadAction.isEnabled)
        #expect(job.reloadAction.operation == .job(.reload, job))
    }

    /// 停止の代わりに再開が同じ位置に来る。読み込みは再開が行うので、読み込み直すは無効にする
    @Test(arguments: [(true, false), (false, true), (true, true)])
    func disabledJobOffersResumeOnly(isDisabledFile: Bool, isDisabledLabel: Bool) {
        let job = MonitoredItem.LaunchdJob.stub(isDisabledFile: isDisabledFile, isDisabledLabel: isDisabledLabel, service: Self.loaded)
        let actions = job.controlActions
        #expect(actions.map(\.title) == ["Run Now", "Resume"])
        #expect(actions.map(\.isEnabled) == [false, true])
        #expect(actions[1].operation == .job(.resume, job))
        #expect(!job.reloadAction.isEnabled)
    }

    /// 停止は無効化なので一時停止の絵、再開はその対。今すぐ実行は再開と並んでも見分けられる形にする
    @Test(arguments: [(false, "pause.circle"), (true, "play.circle")])
    func toggleSymbolPairsPauseAndPlay(isDisabled: Bool, toggleSymbol: String) {
        let job = MonitoredItem.LaunchdJob.stub(isDisabledFile: isDisabled, service: Self.loaded)
        #expect(job.controlActions.map(\.systemImage) == ["play.fill", toggleSymbol])
    }

    @Test func onlyLaunchdJobsHaveSecondaryControls() {
        let job = MonitoredItem.LaunchdJob.stub()
        let item = MonitoredItem(key: job.label, name: job.label, status: .failed(reason: "Not loaded"), detail: .launchdJob(job))
        #expect(item.secondaryControlActions.map(\.title) == ["Reload"])
        #expect(MonitoredItem.samples.filter { $0.kind != .launchdJob }.allSatisfy { $0.secondaryControlActions.isEmpty })
    }

    /// メニューバーの「項目」は選んでいるものによらず同じ3つを並べ、launchd ジョブ以外ではすべて無効にする
    @Test func menuActionsKeepSameTitles() throws {
        let job = MonitoredItem.LaunchdJob.stub(service: Self.loaded)
        let item = MonitoredItem(key: job.label, name: job.label, status: .ok, detail: .launchdJob(job))
        let actions = try #require(item.launchdJobActions)
        #expect(actions.map(\.title) == ItemAction.unavailableJobActions.map(\.title))
        #expect(actions.map(\.systemImage) == ItemAction.unavailableJobActions.map(\.systemImage))
        #expect(actions.map(\.isEnabled) == [true, true, false])
        #expect(ItemAction.unavailableJobActions.allSatisfy { !$0.isEnabled })
        #expect(MonitoredItem.samples.filter { $0.kind != .launchdJob }.allSatisfy { $0.launchdJobActions == nil })
    }

    @Test(arguments: [
        (ItemStatus.failed(reason: "Exit code 1"), false, LaunchdServiceInfo?.some(ItemActionTests.loaded), "Run Again", JobActions.Command.runNow),
        (HealthCheck.missedRunStatus(Date(timeIntervalSince1970: 1_800_000_000)), false, ItemActionTests.loaded, "Run Again", .runNow),
        (.failed(reason: "Not loaded"), false, nil, "Reload", .reload),
        (.inactive(reason: "Disabled", note: ".plist.disabled"), true, nil, "Enable", .resume),
        (.inactive(reason: "Disabled", note: ".plist.disabled"), true, ItemActionTests.loaded, "Enable", .resume),
    ])
    func recoveryMatchesStatus(
        status: ItemStatus,
        isDisabledFile: Bool,
        service: LaunchdServiceInfo?,
        title: String,
        command: JobActions.Command
    ) throws {
        let job = MonitoredItem.LaunchdJob.stub(isDisabledFile: isDisabledFile, service: service)
        let item = MonitoredItem(key: job.label, name: job.label, status: status, detail: .launchdJob(job))
        let recovery = try #require(item.recoveryAction)
        #expect(recovery.title == title)
        #expect(recovery.operation == .job(command, job))
        #expect(recovery.isEnabled)
    }

    @Test(arguments: [(ItemStatus.ok, ItemActionTests.loaded), (.running, ItemActionTests.running)])
    func healthyJobHasNoRecovery(status: ItemStatus, service: LaunchdServiceInfo) {
        let job = MonitoredItem.LaunchdJob.stub(service: service)
        let item = MonitoredItem(key: job.label, name: job.label, status: status, detail: .launchdJob(job))
        #expect(item.recoveryAction == nil)
    }

    /// 走り直しても直らない失敗は、直す先（定義ファイル・ログ）を見せる。どれも既にあるファイルの操作と同じもの
    @Test func launchdRecoveryShowsWhereToFix() throws {
        let job = MonitoredItem.LaunchdJob.stub(standardOutPath: "/tmp/job.log", standardErrorPath: "/tmp/job.err.log", service: Self.loaded)
        func recovery(_ status: ItemStatus) -> ItemAction? {
            MonitoredItem(key: job.label, name: job.label, status: status, detail: .launchdJob(job)).recoveryAction
        }

        for reason in ["Script not found", "Executable not found", "Working directory not found", "Log folder not found"] {
            let action = try #require(recovery(.failed(reason: reason, note: "~/x")))
            #expect(action.title == "Show plist in Finder")
            #expect(action.operation == .reveal(job.plistURL))
        }

        let log = try #require(recovery(HealthCheck.logErrorStatus("Error: boom")))
        #expect(log.title == "Open Standard Error Log")
        #expect(log.operation == .open(URL(filePath: "/tmp/job.err.log")))
        // ツールバーのファイルの操作と同じもの
        #expect(job.fileActions(home: URL(filePath: "/Users/me"), fileManager: .default).contains(log))
    }

    /// cron は Breaker から走らせられないので、ログのエラーのときにログを開くだけ
    @Test func cronRecoveryOpensLogOnlyForLogError() {
        let job = MonitoredItem.CronJob(
            line: "0 * * * * /bin/x > /tmp/x.log",
            expression: "0 * * * *",
            command: "/bin/x > /tmp/x.log",
            schedule: nil,
            isReboot: false,
            standardOutPath: "/tmp/x.log",
            standardErrorPath: nil,
            lastRun: nil,
            firstPath: "/bin/x"
        )
        func recovery(_ status: ItemStatus) -> ItemAction? {
            MonitoredItem(key: "x", name: "x", status: status, detail: .cronJob(job)).recoveryAction
        }
        #expect(recovery(HealthCheck.logErrorStatus("Error: boom"))?.operation == .open(URL(filePath: "/tmp/x.log")))
        #expect(recovery(.failed(reason: "Executable not found", note: "/bin/x")) == nil)
        #expect(recovery(HealthCheck.missedRunStatus(.now)) == nil)
        #expect(recovery(.ok) == nil)
    }

    /// /Applications の外から動いているアプリは、どこにあるかを Finder で見せる
    @Test func appOutsideApplicationsRecoversByRevealing() {
        let appURL = URL(filePath: "/tmp/build/Example.app")
        let item = MonitoredItem(
            key: "dev.example",
            name: "Example",
            status: .warning(reason: "Running from outside /Applications", note: appURL.path(percentEncoded: false)),
            detail: .monitoredApp(.init(bundleID: "dev.example", appURL: appURL, isRunning: true))
        )
        #expect(item.recoveryAction?.title == "Show in Finder")
        #expect(item.recoveryAction?.operation == .reveal(appURL))
    }

    @Test(arguments: [true, false])
    func monitoredAppRecoversByLaunching(isRunning: Bool) {
        let appURL = URL(filePath: "/Applications/Example.app")
        let item = MonitoredItem(
            key: "dev.example",
            name: "Example",
            status: isRunning ? .running : .inactive(reason: "Not running"),
            detail: .monitoredApp(.init(bundleID: "dev.example", appURL: appURL, isRunning: isRunning))
        )
        #expect(item.recoveryAction?.operation == (isRunning ? nil : .launchApp(appURL)))
        #expect(item.recoveryAction?.title == (isRunning ? nil : "Launch"))
    }

    @Test func otherKindsHaveNoRecovery() {
        let others = MonitoredItem.samples.filter { $0.kind != .launchdJob && $0.kind != .monitoredApp } + [MonitoredItem.sampleSwiftBarPlugin]
        #expect(!others.isEmpty)
        #expect(others.allSatisfy { $0.recoveryAction == nil })
    }

    @Test func sharedLogIsOfferedOnce() throws {
        let directory = try TemporaryDirectory()
        let job = MonitoredItem.LaunchdJob.stub(standardOutPath: "/tmp/job.log", standardErrorPath: "/tmp/job.log")
        let titles = job.fileActions(home: directory.url, fileManager: .default).map(\.title)
        #expect(titles == ["Open Log", "Open plist", "Show plist in Finder"])
    }

    @Test func separateLogsAndScriptUnderHome() throws {
        let directory = try TemporaryDirectory()
        let scriptURL = directory.url.appending(path: "dev/run.py")
        try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: scriptURL)
        let job = MonitoredItem.LaunchdJob.stub(
            programArguments: ["/usr/bin/python3", "~/dev", "~/dev/run.py", "--quiet"],
            standardOutPath: "/tmp/job.log",
            standardErrorPath: "/tmp/job.err.log"
        )

        let actions = job.fileActions(home: directory.url, fileManager: .default)

        #expect(actions.map(\.title) == ["Open Standard Output Log", "Open Standard Error Log", "Open Script", "Open plist", "Show plist in Finder"])
        // ディレクトリの `~/dev` は飛ばし、ホーム外のインタプリタも選ばない
        #expect(actions[2].operation == .openAsText(URL(filePath: scriptURL.path(percentEncoded: false))))
    }

    @Test func symlinkedPlistOffersDestination() throws {
        let directory = try TemporaryDirectory()
        let targetURL = directory.url.appending(path: "repo/job.plist")
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: targetURL)
        let linkURL = directory.url.appending(path: "com.example.job.plist")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let actions = MonitoredItem.LaunchdJob.stub(plistURL: linkURL).fileActions(home: directory.url, fileManager: .default)

        #expect(actions.map(\.operation).contains(.reveal(linkURL)))
        #expect(actions.last?.title == "Show Linked plist in Finder")
        #expect(actions.last?.operation == .reveal(targetURL.resolvingSymlinksInPath()))
    }

    @Test func folderActionRevealsFoundScriptsOnly() throws {
        let directory = try TemporaryDirectory()
        let scriptsURL = directory.url.appending(path: "Library/Scripts/Folder Action Scripts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scriptsURL, withIntermediateDirectories: true)
        try Data().write(to: scriptsURL.appending(path: "rename.scpt"))
        let folderURL = URL(filePath: "/tmp/Inbox", directoryHint: .isDirectory)
        let item = MonitoredItem(
            key: "/tmp/Inbox",
            name: "Inbox",
            status: .ok,
            detail: .folderAction(.init(folderURL: folderURL, scriptNames: ["rename.scpt", "missing.scpt"], isEnabled: true))
        )

        let actions = item.fileActions(home: directory.url, fileManager: .default)

        #expect(item.controlActions.isEmpty)
        #expect(actions.map(\.title) == ["Open Folder", "Show rename.scpt in Finder"])
        #expect(actions.map(\.operation) == [.open(folderURL), .reveal(scriptsURL.appending(path: "rename.scpt"))])
    }

    @Test(arguments: [true, false])
    func monitoredAppLaunchesOnlyWhenNotRunning(isRunning: Bool) {
        let appURL = URL(filePath: "/Applications/Example.app")
        let item = MonitoredItem(
            key: "dev.example",
            name: "Example",
            status: .ok,
            detail: .monitoredApp(.init(bundleID: "dev.example", appURL: appURL, isRunning: isRunning))
        )
        #expect(item.controlActions.map(\.operation) == [.launchApp(appURL)])
        #expect(item.controlActions.map(\.isEnabled) == [!isRunning])
        #expect(item.fileActions().map(\.operation) == [.reveal(appURL)])
    }

    @Test func onlyLaunchdJobsOfferScheduleEditing() {
        let job = MonitoredItem.LaunchdJob.stub(isDisabledFile: true)
        let item = MonitoredItem(key: job.label, name: job.label, status: .ok, detail: .launchdJob(job))
        #expect(item.editActions.map(\.title) == ["Edit Schedule…"])
        #expect(item.editActions.map(\.operation) == [.editSchedule(job)])
        #expect(!ItemAction.Operation.editSchedule(job).changesState)
        #expect(MonitoredItem.samples.filter { $0.kind != .launchdJob }.allSatisfy { $0.editActions.isEmpty })
    }

    @Test func sourceFailureHasNoActions() {
        #expect(MonitoredItem.sampleSourceFailure.editActions.isEmpty)
        #expect(MonitoredItem.sampleSourceFailure.controlActions.isEmpty)
        #expect(MonitoredItem.sampleSourceFailure.fileActions().isEmpty)
    }

    /**
     `/Library` のジョブは管理者権限が要るので、ツールバーとメニューバーでは同じ組を無効で見せ、右クリック（使えるものだけ）では出さない。
     概要の復旧ボタンとスケジュールの編集も出さず、開く・Finder で表示だけを残す
     */
    @Test(arguments: [MonitoredItem.LaunchdJob.Origin.systemAgent, .daemon])
    func libraryJobIsReadOnly(origin: MonitoredItem.LaunchdJob.Origin) throws {
        for (service, isDisabledLabel) in [(Self.loaded, false), (nil, false), (Self.loaded, true)] as [(LaunchdServiceInfo?, Bool)] {
            let job = MonitoredItem.LaunchdJob.stub(isDisabledLabel: isDisabledLabel, service: service, origin: origin)
            let item = MonitoredItem(key: "/\(origin.relativePath)/\(job.label)", name: job.label, status: .failed(reason: "Exit code 1"), detail: .launchdJob(job))
            #expect(item.controlActions.count == 2)
            #expect(item.controlActions.allSatisfy { !$0.isEnabled })
            #expect(item.secondaryControlActions.map(\.title) == ["Reload"])
            #expect(item.secondaryControlActions.allSatisfy { !$0.isEnabled })
            let menu = try #require(item.launchdJobActions)
            #expect(menu.count == 3)
            #expect(menu.allSatisfy { !$0.isEnabled })
            #expect((item.controlActions + item.secondaryControlActions).filter(\.isEnabled).isEmpty)
            #expect(item.recoveryAction == nil)
            #expect(item.editActions.isEmpty)
            #expect(Set(item.fileActions().map(\.title)).isSuperset(of: ["Open plist", "Show plist in Finder"]))
        }
    }
}
