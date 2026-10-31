import Foundation
import Testing
@testable import Breaker

@MainActor
struct AppModelTests {
    @Test func refreshReplacesItemsAndRecordsDate() async {
        let appModel = AppModel { MonitoredItem.samples }
        #expect(appModel.items.isEmpty)
        #expect(appModel.lastRefreshDate == nil)

        await appModel.refresh()
        #expect(appModel.items == MonitoredItem.samples)
        #expect(appModel.lastRefreshDate != nil)
        #expect(!appModel.isRefreshing)
    }

    /// 異常は先頭の要確認の節に集まり、種類ごとの節には残りだけが種類の順に並ぶ。どの項目も1つの節にだけ入る
    @Test func sectionsFollowKindOrder() throws {
        let defaults = try IsolatedDefaults()
        let appModel = AppModel(items: MonitoredItem.samples, defaults: defaults.userDefaults)
        appModel.launchdScope = .all
        let sections = appModel.sections
        let healthyKinds = MonitoredItem.Kind.allCases.filter { kind in
            MonitoredItem.samples.contains { $0.kind == kind && !$0.status.isAbnormal }
        }
        #expect(sections.map(\.group) == [.attention] + healthyKinds.map { .kind($0) })
        #expect(sections[0].items.allSatisfy { $0.status.isAbnormal })
        #expect(sections.dropFirst().allSatisfy { $0.items.allSatisfy { !$0.status.isAbnormal } })
        let ids = sections.flatMap(\.items).map(\.id)
        #expect(ids.count == MonitoredItem.samples.count)
        #expect(Set(ids) == Set(MonitoredItem.samples.map(\.id)))
    }

    /// 要確認の節は種類を問わず失敗を上にし、同じ重さの中は検出の並び（種類 → 名前）のまま
    @Test func attentionSectionPutsFailuresFirst() throws {
        let defaults = try IsolatedDefaults()
        let items = [
            Self.job("job-warn", status: .warning(reason: "x")),
            Self.job("job-fail", status: .failed(reason: "Exit code 1")),
            Self.job("job-ok", status: .ok),
            Self.plugin("plugin-warn", status: .warning(reason: "x")),
            Self.plugin("plugin-fail", status: .failed(reason: "x")),
            Self.plugin("plugin-stopped", status: .inactive(reason: "x")),
        ]
        let appModel = AppModel(items: items, defaults: defaults.userDefaults)
        let sections = appModel.sections
        #expect(sections.map(\.group) == [.attention, .kind(.launchdJob), .kind(.swiftBarPlugin)])
        #expect(sections.map { $0.items.map(\.name) } == [["job-fail", "plugin-fail", "job-warn", "plugin-warn"], ["job-ok"], ["plugin-stopped"]])
    }

    /// 異常が無ければ要確認の節は出さない
    @Test func attentionSectionHiddenWithoutIssues() throws {
        let defaults = try IsolatedDefaults()
        let appModel = AppModel(items: Self.scopedItems(status: .ok), defaults: defaults.userDefaults)
        #expect(!appModel.sections.map(\.group).contains(.attention))
    }

    /// 異常のみでは要確認の節だけになる。launchd の表示範囲は要確認の節にも効く
    @Test func abnormalOnlyLeavesAttentionSection() throws {
        let defaults = try IsolatedDefaults()
        let items = Self.scopedItems(status: .failed(reason: "Exit code 1")) + [Self.job("ok", status: .ok)]
        let appModel = AppModel(items: items, defaults: defaults.userDefaults)
        #expect(appModel.sections.map(\.group) == [.attention, .kind(.launchdJob)])
        #expect(appModel.sections[0].items.map(\.name) == ["home", "plugin.sh"])

        appModel.showsAbnormalOnly = true
        #expect(appModel.sections.map(\.group) == [.attention])

        appModel.launchdScope = .daemons
        #expect(appModel.sections[0].items.map(\.name) == ["daemon", "plugin.sh"])
    }

    /// 異常になって要確認の節へ移っても、ID が変わらないので同じ項目を選んだまま
    @Test func selectionFollowsItemAcrossSections() async throws {
        let defaults = try IsolatedDefaults()
        let failed = ItemStatus.failed(reason: "Exit code 1")
        let results = DiscoverResults([[Self.job("home", status: .ok)], [Self.job("home", status: failed)]])
        let appModel = AppModel(defaults: defaults.userDefaults) { await results.next() }
        await appModel.refresh()
        let id = try #require(appModel.sections.first?.items.first?.id)
        appModel.selectedID = id
        #expect(appModel.sections.map(\.group) == [.kind(.launchdJob)])

        await appModel.refresh()
        #expect(appModel.sections.map(\.group) == [.attention])
        #expect(appModel.sections[0].items.map(\.id) == [id])
        #expect(appModel.selectedItem?.status == failed)
    }

    @Test func abnormalOnlyFilterKeepsSelection() throws {
        let defaults = try IsolatedDefaults()
        let appModel = AppModel(items: MonitoredItem.samples, defaults: defaults.userDefaults)
        let ok = MonitoredItem.samples[0]
        appModel.selectedID = ok.id
        appModel.showsAbnormalOnly = true

        let visible = appModel.sections.flatMap(\.items)
        #expect(!visible.isEmpty)
        #expect(visible.allSatisfy { $0.status.isAbnormal })
        #expect(appModel.selectedItem == ok)
    }

    /// 初期値はホームで、絞り込みボタンは塗らない。ホーム以外を選ぶか異常のみにしたときだけ塗る
    @Test func defaultFilterIsHome() throws {
        let defaults = try IsolatedDefaults()
        let appModel = AppModel(defaults: defaults.userDefaults)
        #expect(appModel.launchdScope == .home)
        #expect(!appModel.showsAbnormalOnly)
        #expect(!appModel.hasCustomFilter)

        appModel.launchdScope = .daemons
        #expect(appModel.hasCustomFilter)
        appModel.launchdScope = .home
        appModel.showsAbnormalOnly = true
        #expect(appModel.hasCustomFilter)
    }

    /// 表示範囲は launchd ジョブだけを絞り、launchd 以外の項目はどの範囲でも出る
    @Test(arguments: [
        (AppModel.LaunchdScope.home, ["home"]),
        (.userAgents, ["home", "app"]),
        (.systemAgents, ["systemAgent"]),
        (.daemons, ["daemon"]),
        (.all, ["home", "app", "systemAgent", "daemon"]),
    ])
    func scopeSelectsLaunchdJobs(scope: AppModel.LaunchdScope, expected: [String]) throws {
        let defaults = try IsolatedDefaults()
        let items = Self.scopedItems(status: .ok)
        let appModel = AppModel(items: items, defaults: defaults.userDefaults)
        appModel.launchdScope = scope

        let visible = appModel.sections.flatMap(\.items)
        #expect(visible.filter { $0.kind == .launchdJob }.map(\.name) == expected)
        #expect(visible.contains { $0.kind == .swiftBarPlugin })
    }

    /// 異常のみは表示範囲と重ねて効く
    @Test func abnormalOnlyCombinesWithScope() throws {
        let defaults = try IsolatedDefaults()
        let items = [
            Self.job("home", status: .failed(reason: "Exit code 1")),
            Self.job("app", isHomeJob: false, status: .ok),
            Self.job("daemon", origin: .daemon, status: .failed(reason: "Exit code 1")),
            Self.job("quiet", origin: .daemon, status: .ok),
            MonitoredItem.sampleSwiftBarPlugin,
        ]
        let appModel = AppModel(items: items, defaults: defaults.userDefaults)
        appModel.showsAbnormalOnly = true
        #expect(appModel.sections.flatMap(\.items).map(\.name) == ["home"])

        appModel.launchdScope = .daemons
        #expect(appModel.sections.flatMap(\.items).map(\.name) == ["daemon"])

        appModel.launchdScope = .all
        #expect(appModel.sections.flatMap(\.items).map(\.name) == ["home", "daemon"])
    }

    @Test func filtersPersistAcrossInstances() throws {
        let defaults = try IsolatedDefaults()
        let appModel = AppModel(defaults: defaults.userDefaults)
        appModel.showsAbnormalOnly = true
        appModel.launchdScope = .systemAgents

        let reloaded = AppModel(defaults: defaults.userDefaults)

        #expect(reloaded.showsAbnormalOnly)
        #expect(reloaded.launchdScope == .systemAgents)
        #expect(defaults.userDefaults.string(forKey: "launchdScope") == "systemAgents")
    }

    /// 保存された値が読めなければホームに戻す
    @Test func unknownStoredScopeFallsBackToHome() throws {
        let defaults = try IsolatedDefaults()
        defaults.userDefaults.set("mine", forKey: "launchdScope")
        #expect(AppModel(defaults: defaults.userDefaults).launchdScope == .home)
    }

    /// 通知・Dock バッジの件数は、ホームのジョブと launchd 以外の異常だけを数える
    @Test func abnormalCountSkipsAppJobs() throws {
        let defaults = try IsolatedDefaults()
        let items = [
            Self.job("a", status: .failed(reason: "Exit code 1")),
            Self.job("b", status: HealthCheck.logErrorStatus("Error: boom")),
            Self.job("c", status: .warning(reason: "Can't Get")),
            Self.job("d", status: .ok),
            Self.job("e", status: .inactive(reason: "Disabled")),
            // アプリが入れたジョブは数えない
            Self.job("f", isHomeJob: false, status: .failed(reason: "Exit code 1")),
        ]
        let appModel = AppModel(items: items, defaults: defaults.userDefaults)
        #expect(appModel.abnormalCount == 3)
    }

    /// 件数はホームのジョブと launchd 以外だけを数え、表示範囲を変えても変わらない
    @Test func abnormalCountIgnoresScope() throws {
        let defaults = try IsolatedDefaults()
        let items = Self.scopedItems(status: .failed(reason: "Exit code 1"))
        let appModel = AppModel(items: items, defaults: defaults.userDefaults)
        for scope in AppModel.LaunchdScope.allCases {
            appModel.launchdScope = scope
            #expect(appModel.abnormalCount == 2)
        }
    }

    @Test func emptyReasonMatchesFilters() throws {
        let defaults = try IsolatedDefaults()
        let appModel = AppModel(items: [], defaults: defaults.userDefaults)
        #expect(appModel.emptyReason == .noItems)

        let appFailure = AppModel(items: [Self.job("app", isHomeJob: false, status: .failed(reason: "Exit code 1"))], defaults: defaults.userDefaults)
        #expect(appFailure.emptyReason == .noJobs(in: .home))
        appFailure.showsAbnormalOnly = true
        #expect(appFailure.emptyReason == .noAbnormal(hidesAbnormal: true))
        appFailure.launchdScope = .daemons
        #expect(appFailure.emptyReason == .noAbnormal(hidesAbnormal: true))
        appFailure.showsAbnormalOnly = false
        #expect(appFailure.emptyReason == .noJobs(in: .daemons))
        appFailure.launchdScope = .userAgents
        #expect(appFailure.emptyReason == nil)

        let healthy = AppModel(items: [Self.job("home", status: .ok), Self.job("app", isHomeJob: false, status: .ok)], defaults: defaults.userDefaults)
        healthy.showsAbnormalOnly = true
        #expect(healthy.emptyReason == .noAbnormal(hidesAbnormal: false))
        healthy.showsAbnormalOnly = false
        #expect(healthy.emptyReason == nil)
    }

    /// 件数・まとめの通知から異常を出すとき、ホームのジョブが隠れる範囲ならホームに戻す
    @Test(arguments: [
        (AppModel.LaunchdScope.home, AppModel.LaunchdScope.home),
        (.userAgents, .userAgents),
        (.systemAgents, .home),
        (.daemons, .home),
        (.all, .all),
    ])
    func showReportedAbnormalKeepsHomeJobsVisible(scope: AppModel.LaunchdScope, expected: AppModel.LaunchdScope) throws {
        let defaults = try IsolatedDefaults()
        let appModel = AppModel(defaults: defaults.userDefaults)
        appModel.launchdScope = scope
        appModel.showReportedAbnormal()
        #expect(appModel.showsAbnormalOnly)
        #expect(appModel.launchdScope == expected)
    }

    @Test func stopWaitsForConfirmation() async throws {
        let shell = StubShell(output: ShellOutput(status: 0, stdout: "", stderr: ""))
        let appModel = appModel(shell: shell)
        let item = MonitoredItem.samples[0]
        let stop = try #require(item.controlActions.first { $0.title == "Stop" })

        await appModel.request(stop, on: item)
        #expect(appModel.isConfirming)
        #expect(shell.calls.isEmpty)

        appModel.isConfirming = false
        #expect(appModel.pendingAction == nil)
    }

    @Test func actionRunsLaunchctlAndRefreshes() async throws {
        let shell = StubShell(output: ShellOutput(status: 0, stdout: "", stderr: ""))
        let appModel = appModel(shell: shell)
        let item = MonitoredItem.samples[0]
        let runNow = try #require(item.controlActions.first)

        await appModel.request(runNow, on: item)

        #expect(shell.calls.map(\.arguments.first) == ["kickstart"])
        #expect(appModel.lastRefreshDate != nil)
        #expect(appModel.actingItemID == nil)
        #expect(!appModel.isShowingFailure)
    }

    @Test func failureShowsLaunchctlMessageAndStillRefreshes() async throws {
        let shell = StubShell(output: ShellOutput(status: 37, stdout: "", stderr: "Operation already in progress"))
        let appModel = appModel(shell: shell)
        let item = MonitoredItem.samples[0]

        await appModel.perform(try #require(item.controlActions.first), on: item)

        #expect(appModel.isShowingFailure)
        #expect(appModel.failureMessage?.contains("Operation already in progress") == true)
        #expect(appModel.lastRefreshDate != nil)
        appModel.isShowingFailure = false
        #expect(appModel.failureMessage == nil)
    }

    @Test func disabledActionDoesNothing() async throws {
        let shell = StubShell(output: ShellOutput(status: 0, stdout: "", stderr: ""))
        let appModel = appModel(shell: shell)
        let running = MonitoredItem.samples[1]
        let runNow = try #require(running.controlActions.first)
        #expect(!runNow.isEnabled)

        await appModel.perform(runNow, on: running)

        #expect(shell.calls.isEmpty)
        #expect(appModel.lastRefreshDate == nil)
    }

    @Test func editScheduleOpensSheetWithoutRunningAnything() async throws {
        let shell = StubShell(output: ShellOutput(status: 0, stdout: "", stderr: ""))
        let appModel = appModel(shell: shell)
        let item = MonitoredItem.samples[0]
        let edit = try #require(item.editActions.first)

        await appModel.request(edit, on: item)

        #expect(appModel.scheduleEditing?.id == item.id)
        #expect(appModel.scheduleEditing?.hasComments == false)
        #expect(shell.calls.isEmpty)
        #expect(appModel.lastRefreshDate == nil)
    }

    @Test func savingScheduleWritesClosesSheetAndRefreshes() async throws {
        var written = [(Schedule, String)]()
        let appModel = AppModel(items: MonitoredItem.samples, discover: { MonitoredItem.samples }) { written.append(($0, $1.label)) }
        let item = MonitoredItem.samples[0]
        await appModel.request(try #require(item.editActions.first), on: item)
        let editing = try #require(appModel.scheduleEditing)

        await appModel.saveSchedule(Schedule(interval: 600), for: editing)

        #expect(written.map(\.0) == [Schedule(interval: 600)])
        #expect(written.map(\.1) == [editing.job.label])
        #expect(appModel.scheduleEditing == nil)
        #expect(appModel.actingItemID == nil)
        #expect(appModel.lastRefreshDate != nil)
        #expect(!appModel.isShowingFailure)
        #expect(appModel.scheduleSaveFailure == nil)
    }

    /// 失敗してもシートは同じ対象のまま開いておく（シートの @State の入力が残る）。理由はシートの中に出し、一覧のアラートは出さない
    @Test func scheduleSaveFailureKeepsSheetOpenWithMessage() async throws {
        let appModel = AppModel(items: MonitoredItem.samples, discover: { MonitoredItem.samples }) { _, _ in throw PlistEditorError.lintFailed("bad") }
        let item = MonitoredItem.samples[0]
        await appModel.request(try #require(item.editActions.first), on: item)
        let editing = try #require(appModel.scheduleEditing)

        await appModel.saveSchedule(Schedule(interval: 600), for: editing)

        #expect(appModel.scheduleEditing?.id == editing.id)
        #expect(appModel.scheduleEditing?.job == editing.job)
        #expect(appModel.scheduleSaveFailure?.contains("bad") == true)
        #expect(!appModel.isShowingFailure)
        #expect(appModel.actingItemID == nil)
        #expect(appModel.lastRefreshDate != nil)
    }

    @Test func retryAfterFailureClosesSheetAndClearsMessage() async throws {
        var attempts = 0
        let appModel = AppModel(items: MonitoredItem.samples, discover: { MonitoredItem.samples }) { _, _ in
            attempts += 1
            if attempts == 1 {
                throw PlistEditorError.lintFailed("bad")
            }
        }
        let item = MonitoredItem.samples[0]
        await appModel.request(try #require(item.editActions.first), on: item)
        let editing = try #require(appModel.scheduleEditing)

        await appModel.saveSchedule(Schedule(interval: 600), for: editing)
        #expect(appModel.scheduleSaveFailure != nil)

        await appModel.saveSchedule(Schedule(interval: 900), for: editing)
        #expect(attempts == 2)
        #expect(appModel.scheduleEditing == nil)
        #expect(appModel.scheduleSaveFailure == nil)
    }

    /// 前回の失敗を、次に開いたシートに持ち越さない
    @Test func reopeningSheetClearsPreviousFailure() async throws {
        let appModel = AppModel(items: MonitoredItem.samples, discover: { MonitoredItem.samples }) { _, _ in throw PlistEditorError.lintFailed("bad") }
        let item = MonitoredItem.samples[0]
        let edit = try #require(item.editActions.first)
        await appModel.request(edit, on: item)
        await appModel.saveSchedule(Schedule(interval: 600), for: try #require(appModel.scheduleEditing))
        appModel.scheduleEditing = nil

        await appModel.request(edit, on: item)

        #expect(appModel.scheduleEditing != nil)
        #expect(appModel.scheduleSaveFailure == nil)
    }

    @Test func saveNoteTrimsWhitespace() throws {
        let defaults = try IsolatedDefaults()
        let item = MonitoredItem.samples[0]
        let appModel = AppModel(defaults: defaults.userDefaults)

        appModel.saveNote("  メモ \n", for: item)

        #expect(appModel.itemNotes[item.id] == "メモ")
    }

    @Test func blankNoteRemovesNote() throws {
        let defaults = try IsolatedDefaults()
        let item = MonitoredItem.samples[0]
        let appModel = AppModel(defaults: defaults.userDefaults)
        appModel.saveNote("メモ", for: item)

        appModel.saveNote("   ", for: item)

        #expect(appModel.itemNotes[item.id] == nil)
    }

    @Test func notesPersistAcrossInstances() throws {
        let defaults = try IsolatedDefaults()
        let item = MonitoredItem.samples[0]
        AppModel(defaults: defaults.userDefaults).saveNote("メモ", for: item)

        let reloaded = AppModel(defaults: defaults.userDefaults)

        #expect(reloaded.itemNotes == [item.id: "メモ"])
    }

    /// スクリーンショット用の見本。見本の項目がすべて並び、ログの書かれた失敗の項目を選んだ状態で始まる
    @Test func sampleDataSelectsFailureWithLogs() throws {
        let appModel = AppModel.sampleData()
        let selected = try #require(appModel.selectedItem)
        guard case .launchdJob(let job) = selected.detail else {
            Issue.record("選ばれた項目が launchd ジョブではない")
            return
        }

        #expect(Set(appModel.items.map(\.id)) == Set(MonitoredItem.samples.map(\.id)))
        #expect(selected.id == MonitoredItem.sampleFailureWithLogs.id)
        #expect(selected.status.isFailed)
        #expect(FileManager.default.fileExists(atPath: try #require(job.standardErrorPath)))
    }

    /// 更新しても実際の検出を走らせず、同じ見本を返し直す
    @Test func sampleDataRefreshKeepsSamples() async {
        let appModel = AppModel.sampleData()
        let before = appModel.items

        await appModel.refresh()

        #expect(appModel.items == before)
    }

    private static func job(
        _ label: String,
        isHomeJob: Bool = true,
        origin: MonitoredItem.LaunchdJob.Origin = .userAgent,
        status: ItemStatus
    ) -> MonitoredItem {
        let job = MonitoredItem.LaunchdJob.sample(label, schedule: Schedule(), isHomeJob: isHomeJob && origin == .userAgent, origin: origin)
        return MonitoredItem(key: "\(origin):\(label)", name: label, status: status, detail: .launchdJob(job))
    }

    private static func plugin(_ name: String, status: ItemStatus) -> MonitoredItem {
        MonitoredItem(
            key: "/tmp/\(name)",
            name: name,
            status: status,
            detail: .swiftBarPlugin(.init(fileURL: URL(filePath: "/tmp/\(name)"), refreshInterval: nil))
        )
    }

    /// 表示範囲の選択肢ごとに1つずつ入る launchd ジョブと、launchd 以外の項目
    static func scopedItems(status: ItemStatus) -> [MonitoredItem] {
        [
            job("home", status: status),
            job("app", isHomeJob: false, status: status),
            job("systemAgent", origin: .systemAgent, status: status),
            job("daemon", origin: .daemon, status: status),
            MonitoredItem(
                key: "/tmp/plugin.sh",
                name: "plugin.sh",
                status: status,
                detail: .swiftBarPlugin(.init(fileURL: URL(filePath: "/tmp/plugin.sh"), refreshInterval: nil))
            ),
        ]
    }

    private func appModel(shell: StubShell) -> AppModel {
        let performer = ItemActionPerformer(jobActions: JobActions(launchctl: LaunchctlService(shell: shell, uid: 501)), workspace: StubWorkspace())
        return AppModel(items: MonitoredItem.samples, performer: performer) { MonitoredItem.samples }
    }
}

/// 取り直すたびに、渡した順に一覧を返す検出
private actor DiscoverResults {
    private var results: [[MonitoredItem]]

    init(_ results: [[MonitoredItem]]) {
        self.results = results
    }

    func next() -> [MonitoredItem] {
        results.removeFirst()
    }
}
