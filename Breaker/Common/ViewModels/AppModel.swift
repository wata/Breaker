import Foundation
import Observation

/// 一覧の項目・選択・フィルタを持つ。ウインドウを閉じても続く定期チェックもここで回し、異常を通知と Dock バッジで知らせる
@MainActor
@Observable
final class AppModel {
    struct Section: Identifiable {
        enum Group: Hashable {
            /// 種類を問わず、失敗・要確認の項目を集めて一番上に置く節
            case attention
            /// 種類ごとの節。異常の項目は `attention` に移るので、正常・実行中・停止・未確認だけが残る
            case kind(MonitoredItem.Kind)
        }

        let group: Group
        let items: [MonitoredItem]

        var id: Group {
            group
        }
    }

    /// 確認ダイアログで「停止」が押されるのを待っている操作
    struct PendingAction {
        let action: ItemAction
        let item: MonitoredItem
    }

    /// スケジュール編集シートの対象。コメントの有無はシートを開く時点の plist で決める
    struct ScheduleEditing: Identifiable {
        let item: MonitoredItem
        let job: MonitoredItem.LaunchdJob
        let hasComments: Bool

        var id: MonitoredItem.ID {
            item.id
        }
    }

    /**
     一覧に出す launchd ジョブの範囲。要確認の節の launchd ジョブにも効き、cron・フォルダアクション・SwiftBar・アプリには効かない。
     `userAgents` はホームのジョブもアプリが入れたものも含めた `~/Library/LaunchAgents` のすべて
     */
    enum LaunchdScope: String, CaseIterable, Identifiable {
        case home
        case userAgents
        case systemAgents
        case daemons
        case all

        var id: Self {
            self
        }

        func includes(_ job: MonitoredItem.LaunchdJob) -> Bool {
            switch self {
            case .home:
                job.isHomeJob

            case .userAgents:
                job.origin == .userAgent

            case .systemAgents:
                job.origin == .systemAgent

            case .daemons:
                job.origin == .daemon

            case .all:
                true
            }
        }
    }

    /// 絞り込みで一覧が空になったときに、なぜ空なのかを伝えるための区別
    enum EmptyReason: Equatable {
        case noItems
        /// `hidesAbnormal` は表示範囲の外の launchd ジョブに異常があること（「すべて」にすれば見える）
        case noAbnormal(hidesAbnormal: Bool)
        /// 表示範囲に launchd ジョブが無く、launchd 以外の項目も無い
        case noJobs(in: LaunchdScope)
    }

    /// プレビューやテストでシステムを触らずに固定の項目を返せるよう、検出はクロージャで受け取る
    typealias Discover = @Sendable () async -> [MonitoredItem]
    /// プレビューの保存ボタンで実際の plist を書き換えないよう、書き込みもクロージャで受け取る
    typealias WriteSchedule = @MainActor (Schedule, MonitoredItem.LaunchdJob) async throws -> Void

    private(set) var items: [MonitoredItem]
    private(set) var isRefreshing = false
    private(set) var lastRefreshDate: Date?
    var selectedID: MonitoredItem.ID?
    /// 絞り込みはアプリを終了しても残す
    var showsAbnormalOnly: Bool {
        didSet {
            defaults.set(showsAbnormalOnly, forKey: Self.showsAbnormalOnlyKey)
        }
    }
    /// 初期値はホーム。アプリが入れたジョブや `/Library` のジョブは、見たいときだけ出せば足りる
    var launchdScope: LaunchdScope {
        didSet {
            defaults.set(launchdScope.rawValue, forKey: Self.launchdScopeKey)
        }
    }
    /// 操作中の項目。launchctl の連打で状態が食い違わないよう、操作は同時に1つだけにする
    private(set) var actingItemID: MonitoredItem.ID?
    var pendingAction: PendingAction?
    var failureMessage: String?
    var scheduleEditing: ScheduleEditing?
    /// スケジュール保存の失敗。シートを開いたまま、その中に出す
    private(set) var scheduleSaveFailure: String?
    /// 利用者が詳細ペインで書いた説明。自動で取った説明が合わないときに上書きする
    private(set) var itemNotes: [MonitoredItem.ID: String]

    @ObservationIgnored
    private let discover: Discover
    @ObservationIgnored
    private let performer: ItemActionPerformer
    @ObservationIgnored
    private let writeSchedule: WriteSchedule
    @ObservationIgnored
    private let defaults: UserDefaults
    /// 取得中の更新。重なった依頼はこれの終わりを待つ
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?
    /// 取得中に届いた更新の依頼。何件届いても、今の取得の後に1回だけ取り直す
    @ObservationIgnored
    private var needsRefreshAgain = false
    @ObservationIgnored
    private var monitorTask: Task<Void, Never>?
    /// 定期チェックを始めるまでは nil。テストやプレビューの更新で通知やバッジを出さないため
    @ObservationIgnored
    private var reporter: (any AbnormalReporting)?
    /// 直前に知らせた時点の項目。nil は起動後まだ一度も知らせていないこと
    @ObservationIgnored
    private var reportedItems: [MonitoredItem]?

    init(
        items: [MonitoredItem] = [],
        performer: ItemActionPerformer = ItemActionPerformer(),
        defaults: UserDefaults = .standard,
        // 走っていない検出は取り直しをまたいで launchd の runs と電源の履歴を覚えるので、検出の Source は作り直さず使い続ける
        discover: @escaping Discover = { [discovery = ItemDiscovery()] in await discovery.items() },
        writeSchedule: @escaping WriteSchedule = { try await PlistEditor().save($0, for: $1) }
    ) {
        self.items = items
        self.performer = performer
        self.writeSchedule = writeSchedule
        self.discover = discover
        self.defaults = defaults
        itemNotes = defaults.dictionary(forKey: Self.itemNotesKey) as? [MonitoredItem.ID: String] ?? [:]
        showsAbnormalOnly = defaults.bool(forKey: Self.showsAbnormalOnlyKey)
        launchdScope = defaults.string(forKey: Self.launchdScopeKey).flatMap(LaunchdScope.init(rawValue:)) ?? .home
    }

    /**
     異常がどの種類にあっても一番上で見つかるよう、失敗・要確認を先頭の要確認の節に集め、残りを種類ごとに区切る。
     項目は `ItemDiscovery` が種類 → 状態 → 名前の順に並べて返すので、要確認の節は失敗を上にし、同じ重さの中はその順のままにする。
     異常のみのときは種類ごとの節に残る項目が無いので、要確認の節だけになる。項目は1つの節にだけ入るので、節を移っても選択は ID で続く
     */
    var sections: [Section] {
        let visible = items.filter(isInScope)
        let attention = visible.filter(\.status.isFailed) + visible.filter { $0.status.isAbnormal && !$0.status.isFailed }
        let others = showsAbnormalOnly ? [] : visible.filter { !$0.status.isAbnormal }
        let kinds = MonitoredItem.Kind.allCases.compactMap { kind in
            let items = others.filter { $0.kind == kind }
            return items.isEmpty ? nil : Section(group: .kind(kind), items: items)
        }
        return (attention.isEmpty ? [] : [Section(group: .attention, items: attention)]) + kinds
    }

    /// フィルタで一覧から消えても、選んでいた項目の詳細は出し続ける
    var selectedItem: MonitoredItem? {
        items.first { $0.id == selectedID }
    }

    var isConfirming: Bool {
        get {
            pendingAction != nil
        }
        set {
            if !newValue {
                pendingAction = nil
            }
        }
    }

    var isShowingFailure: Bool {
        get {
            failureMessage != nil
        }
        set {
            if !newValue {
                failureMessage = nil
            }
        }
    }

    /// 絞り込みボタンの記号を塗りにするか。既定（ホーム・異常のみオフ）から変えているときだけ塗る
    var hasCustomFilter: Bool {
        showsAbnormalOnly || launchdScope != .home
    }

    /// 一覧が空のときに出す理由。項目が見えていれば nil
    var emptyReason: EmptyReason? {
        guard sections.isEmpty else {
            return nil
        }
        if items.isEmpty {
            return .noItems
        }
        if showsAbnormalOnly {
            return .noAbnormal(hidesAbnormal: items.contains { $0.status.isAbnormal && !isInScope($0) })
        }
        return .noJobs(in: launchdScope)
    }

    var abnormalCount: Int {
        items.count(where: \.isReportedAbnormal)
    }

    /// 空白だけのメモは消して、自動で取った説明に戻す
    func saveNote(_ note: String, for item: MonitoredItem) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        itemNotes[item.id] = trimmed.isEmpty ? nil : trimmed
        defaults.set(itemNotes, forKey: Self.itemNotesKey)
    }

    /**
     取得中に呼ばれたら捨てずに、今の取得が終わった後にもう1回だけ取り直し、それが終わるまで待つ。
     操作の直後の更新が定期チェックと重なっても、操作後の状態を必ず取り込むため
     */
    func refresh() async {
        if let refreshTask {
            needsRefreshAgain = true
            await refreshTask.value
            return
        }
        isRefreshing = true
        let task = Task {
            repeat {
                needsRefreshAgain = false
                items = await discover()
                lastRefreshDate = .now
                await report()
            } while needsRefreshAgain
            // 終わりの判定から片付けまでの間に中断点を挟まないので、ここで届いた依頼を取りこぼさない
            refreshTask = nil
            isRefreshing = false
        }
        refreshTask = task
        await task.value
    }

    /// すぐに1回取得し、以後 `interval` ごとに取り直す。ウインドウの有無に関係なくアプリが動いている間続ける
    func startMonitoring(reporter: any AbnormalReporting, interval: Duration = .seconds(60)) {
        guard monitorTask == nil else { return }
        self.reporter = reporter
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// 通知のタップで呼ぶ。まとめの通知（id なし）は異常のある項目だけに絞って見せる
    func reveal(itemID: MonitoredItem.ID?) {
        guard let itemID else {
            showReportedAbnormal()
            return
        }
        selectedID = itemID
    }

    /**
     通知・件数に数えた異常（ホームのジョブと launchd 以外の項目）を一覧に出す。
     システムエージェント・デーモンの範囲ではホームのジョブが隠れて数えた異常が見えないので、ホームに戻す
     */
    func showReportedAbnormal() {
        showsAbnormalOnly = true
        if [.systemAgents, .daemons].contains(launchdScope) {
            launchdScope = .home
        }
    }

    /// 詳細ペインのボタンと右クリックメニューの入り口。停止は確認を挟み、スケジュール編集はシートを開く
    func request(_ action: ItemAction, on item: MonitoredItem) async {
        if case .editSchedule(let job) = action.operation {
            scheduleSaveFailure = nil
            scheduleEditing = ScheduleEditing(item: item, job: job, hasComments: PlistEditor.containsComments(at: job.plistURL))
            return
        }
        if
            case .job(let command, _) = action.operation,
            command.needsConfirmation
        {
            pendingAction = PendingAction(action: action, item: item)
            return
        }
        await perform(action, on: item)
    }

    /// 失敗しても状態が途中まで変わっていることがある（disable は通って bootout で失敗など）ので、一覧は必ず取り直す
    func perform(_ action: ItemAction, on item: MonitoredItem) async {
        guard
            action.isEnabled,
            actingItemID == nil
        else {
            return
        }
        actingItemID = item.id
        defer { actingItemID = nil }
        do {
            try await performer.perform(action.operation)
        } catch {
            failureMessage = error.localizedDescription
        }
        if action.operation.changesState {
            await refresh()
        }
    }

    /**
     成功したときだけシートを閉じる。失敗したらシートを開いたまま理由をその中に出し、入力をやり直すかキャンセルできるようにする。
     失敗でも書き込みが途中まで進んでいる（置き換えは済んで読み込み直しで失敗など）ことがあるので、一覧はどちらでも取り直す
     */
    func saveSchedule(_ schedule: Schedule, for editing: ScheduleEditing) async {
        guard actingItemID == nil else { return }
        actingItemID = editing.item.id
        defer { actingItemID = nil }
        scheduleSaveFailure = nil
        do {
            try await writeSchedule(schedule, editing.job)
            scheduleEditing = nil
        } catch {
            scheduleSaveFailure = error.localizedDescription
        }
        await refresh()
    }

    private static let itemNotesKey = "itemNotes"
    private static let showsAbnormalOnlyKey = "showsAbnormalOnly"
    private static let launchdScopeKey = "launchdScope"

    private func isInScope(_ item: MonitoredItem) -> Bool {
        if case .launchdJob(let job) = item.detail {
            launchdScope.includes(job)
        } else {
            true
        }
    }

    private func report() async {
        guard let reporter else { return }
        reporter.showBadge(count: abnormalCount)
        let alerts = AbnormalAlert.alerts(from: reportedItems, to: items)
        reportedItems = items
        await reporter.post(alerts)
    }
}
