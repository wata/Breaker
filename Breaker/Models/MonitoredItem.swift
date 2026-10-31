import Foundation

struct MonitoredItem: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case launchdJob
        case cronJob
        case folderAction
        case swiftBarPlugin
        case monitoredApp
    }

    enum Detail: Hashable, Sendable {
        case launchdJob(LaunchdJob)
        case cronJob(CronJob)
        case folderAction(FolderAction)
        case swiftBarPlugin(SwiftBarPlugin)
        case monitoredApp(MonitoredApp)
        /// その種類の検出自体が失敗した（osascript が拒否された等）。他の種類の表示は続ける
        case sourceFailure(Kind)
    }

    struct LaunchdJob: Hashable, Sendable {
        /**
         plist を置いた場所。`~/Library/LaunchAgents` 以外は書き換えや launchctl の操作に管理者権限が要るので、閲覧だけにする。
         同じラベルが `~/Library/LaunchAgents` と `/Library/LaunchAgents` の両方にあることがある（Google の更新など）
         */
        enum Origin: Hashable, Sendable, CaseIterable {
            /// `~/Library/LaunchAgents`
            case userAgent
            /// `/Library/LaunchAgents`。全ユーザーのログイン時に、各ユーザーの gui ドメインへ読み込まれる
            case systemAgent
            /// `/Library/LaunchDaemons`。system ドメインで root として動く
            case daemon
        }

        let label: String
        let origin: Origin
        /// LaunchAgents 内のパス。シンボリックリンクのことがあるので、書き換えるときはリンク先を解決する
        let plistURL: URL
        /// `*.plist.disabled` にリネームされて launchd から外されている
        let isDisabledFile: Bool
        /// `launchctl disable` 済み。plist はそのままでも、ログインし直しても読み込まれない
        let isDisabledLabel: Bool
        /// ホームにある利用者のスクリプトを動かすジョブ（ホームのジョブ）。false はアプリが入れたジョブで、異常でも通知しない。`/Library` のジョブは常に false
        let isHomeJob: Bool
        let programArguments: [String]
        let schedule: Schedule
        let standardOutPath: String?
        let standardErrorPath: String?
        /// 未ロードのときは nil
        let service: LaunchdServiceInfo?
        /// launchd は最終実行時刻を持たないので、ログファイルの更新時刻と、Breaker が runs の変化で実行を見た時刻の新しいほうで近似する
        let lastRun: Date?
    }

    /// `crontab -l` の1行。解釈できない行も、壊れていることに気づけるよう項目にする
    struct CronJob: Hashable, Sendable {
        /// 前後の空白を除いた行
        let line: String
        /// 時刻の指定（`0 3 * * *`・`@daily`）。解釈できない行は nil
        let expression: String?
        /// 解釈できない行は nil
        let command: String?
        /// `@reboot`・解釈できない行・`Schedule` で表せない指定は nil
        let schedule: Schedule?
        let isReboot: Bool
        let standardOutPath: String?
        let standardErrorPath: String?
        /// cron は最終実行時刻を持たないので、リダイレクト先のログの更新時刻で近似する
        let lastRun: Date?
        /// コマンドの最初のパスを展開したもの。スクリプトを開く操作に使う
        let firstPath: String?
    }

    struct FolderAction: Hashable, Sendable {
        let folderURL: URL
        let scriptNames: [String]
        let isEnabled: Bool
    }

    struct SwiftBarPlugin: Hashable, Sendable {
        let fileURL: URL
        /// ファイル名の `name.5m.sh` の `5m` 部分から解釈した実行間隔
        let refreshInterval: TimeInterval?
    }

    struct MonitoredApp: Hashable, Sendable {
        let bundleID: String
        let appURL: URL
        let isRunning: Bool
    }

    let id: String
    let name: String
    let status: ItemStatus
    let detail: Detail
    /// スクリプトのヘッダーや README から取った用途の説明。取れなければ nil
    let autoDescription: String?

    /// id は種類ごとの一意キー（ラベル・パス・Bundle ID）に種類を前置して作り、種類をまたいだ衝突を防ぐ
    init(key: String, name: String, status: ItemStatus, detail: Detail, autoDescription: String? = nil) {
        self.name = name
        self.status = status
        self.detail = detail
        self.autoDescription = autoDescription
        id = "\(detail.kind.rawValue):\(key)"
    }

    var kind: Kind {
        detail.kind
    }

    /// 通知・件数に数える対象か。cron・フォルダアクション・SwiftBar・監視するアプリは利用者が自分で置いた・選んだものなので、常に true
    var isHomeItem: Bool {
        switch detail {
        case .launchdJob(let job):
            job.isHomeJob

        case .cronJob, .folderAction, .swiftBarPlugin, .monitoredApp, .sourceFailure:
            true
        }
    }

    /// 通知・Dock バッジ・異常の件数に数える異常。ホームのジョブ以外の launchd ジョブは利用者が直すものではないので、一覧の色だけで見せる
    var isReportedAbnormal: Bool {
        status.isAbnormal && isHomeItem
    }
}

extension MonitoredItem.Detail {
    var kind: MonitoredItem.Kind {
        switch self {
        case .launchdJob:
            .launchdJob

        case .cronJob:
            .cronJob

        case .folderAction:
            .folderAction

        case .swiftBarPlugin:
            .swiftBarPlugin

        case .monitoredApp:
            .monitoredApp

        case .sourceFailure(let kind):
            kind
        }
    }
}

extension MonitoredItem.LaunchdJob.Origin {
    /// ホーム（`userAgent`）かルート（それ以外）からの相対パス
    var relativePath: String {
        switch self {
        case .userAgent, .systemAgent:
            "Library/LaunchAgents"

        case .daemon:
            "Library/LaunchDaemons"
        }
    }

    /// 停止・再開・今すぐ実行・読み込み直す・スケジュールの編集ができるか。開く・Finder で表示はどこでもできる
    var isManageable: Bool {
        self == .userAgent
    }
}

extension MonitoredItem.Kind {
    /// サイドバーの節の見出し。英語は節の中に並ぶ項目の数に依らず複数形にする
    var title: String {
        switch self {
        case .launchdJob:
            String(localized: "launchd Jobs")

        case .cronJob:
            String(localized: "cron Jobs", comment: "Sidebar section title for crontab entries")

        case .folderAction:
            String(localized: "Folder Actions")

        case .swiftBarPlugin:
            String(localized: "SwiftBar Plugins")

        case .monitoredApp:
            String(localized: "Apps", comment: "Sidebar section title for monitored apps")
        }
    }

    /// 要確認の節で、種類の混ざった行の理由の前に添える種類の手がかり。launchd・cron・SwiftBar は名前のまま訳さない
    var shortTitle: String {
        switch self {
        case .launchdJob:
            "launchd"

        case .cronJob:
            "cron"

        case .folderAction:
            String(localized: "Folder Action", comment: "A folder action: the section title in the detail pane, and the kind shown before the reason in the sidebar's Needs Attention section")

        case .swiftBarPlugin:
            "SwiftBar"

        case .monitoredApp:
            String(localized: "App", comment: "A monitored app: the section title in the detail pane, and the kind shown before the reason in the sidebar's Needs Attention section")
        }
    }
}
