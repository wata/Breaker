import Foundation

struct MonitoredItem: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        /// 自動化ではないが、つながらないと他の項目も動かないので、要確認の次（一覧の先頭）に置く
        case network
        case launchdJob
        case cronJob
        case folderAction
    }

    enum Detail: Hashable, Sendable {
        case launchdJob(LaunchdJob)
        case cronJob(CronJob)
        case folderAction(FolderAction)
        case network(NetworkHealth)
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
        /// launchd は最小限の PATH で動かすので、plist で PATH などを足しているかを見て失敗の原因を探せるよう持つ。名前の順
        let environmentVariables: [EnvironmentVariable]
        /// 未ロードのときは nil
        let service: LaunchdServiceInfo?
        /// launchd は最終実行時刻を持たないので、ログファイルの更新時刻と、Breaker が runs の変化で実行を見た時刻の新しいほうで近似する
        let lastRun: Date?

        struct EnvironmentVariable: Hashable, Sendable {
            let name: String
            let value: String
        }
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

    let id: String
    let name: String
    let status: ItemStatus
    let detail: Detail
    /// スクリプトのヘッダーや README から取った用途の説明。取れなければ nil
    let autoDescription: String?

    /// id は種類ごとの一意キー（ラベル・パス・crontab の行）に種類を前置して作り、種類をまたいだ衝突を防ぐ
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

    /// 通知・件数に数える対象か。cron・フォルダアクションは利用者が自分で置いたものなので、常に true。ネットワークの通知は `isReportedAbnormal` で別に決める
    var isHomeItem: Bool {
        switch detail {
        case .launchdJob(let job):
            job.isHomeJob

        case .cronJob, .folderAction, .network, .sourceFailure:
            true
        }
    }

    /**
     通知・Dock バッジ・異常の件数に数える異常。ホームのジョブ以外の launchd ジョブは利用者が直すものではないので、一覧の色だけで見せる。
     ネットワークの要確認（遅延・ロス・Wi-Fi が弱い・計測の失敗・ログイン画面）は回線や場所しだいで出入りし、そのたびに知らせると煩いので、
     つながらない失敗だけを数える
     */
    var isReportedAbnormal: Bool {
        if case .network = detail {
            status.isFailed
        } else {
            status.isAbnormal && isHomeItem
        }
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

        case .network:
            .network

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

        case .network:
            Self.networkTitle
        }
    }

    /// 要確認の節で、種類の混ざった行の理由の前に添える種類の手がかり。launchd・cron は名前のまま訳さない
    var shortTitle: String {
        switch self {
        case .launchdJob:
            "launchd"

        case .cronJob:
            "cron"

        case .folderAction:
            String(localized: "Folder Action", comment: "A folder action: the section title in the detail pane, and the kind shown before the reason in the sidebar's Needs Attention section")

        case .network:
            Self.networkTitle
        }
    }

    /// 節の見出しも要確認の行の手がかりも、ネットワークの項目は1つなので同じ言葉にする
    private static var networkTitle: String {
        String(localized: "Network", comment: "The network health check: the sidebar section title, and the kind shown before the reason in the sidebar's Needs Attention section")
    }
}

extension MonitoredItem {
    /// 何のための項目かを書き留める説明の欄を出すか。ネットワークと検出の失敗の行は利用者が置いた自動化ではないので、書くことが無い
    var acceptsNote: Bool {
        switch detail {
        case .launchdJob, .cronJob, .folderAction:
            true

        case .network, .sourceFailure:
            false
        }
    }

    var networkHealth: NetworkHealth? {
        if case .network(let health) = detail {
            health
        } else {
            nil
        }
    }
}
