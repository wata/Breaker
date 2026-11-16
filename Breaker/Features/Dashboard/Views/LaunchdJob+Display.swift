import Foundation

extension MonitoredItem.LaunchdJob {
    /// シンボリックリンクならリンク先。リポジトリで管理している plist を LaunchAgents にリンクしたジョブがある
    var plistDestinationURL: URL? {
        let resolved = plistURL.resolvingSymlinksInPath()
        return resolved == plistURL.standardizedFileURL ? nil : resolved
    }

    /// ファイルの節とログ本文で同じ見出しを使う
    var logFiles: [MonitoredItem.LogFile] {
        MonitoredItem.LogFile.files(standardOutPath: standardOutPath, standardErrorPath: standardErrorPath)
    }

    /// 動き続けている常駐ジョブ（KeepAlive）。詳細では次回の代わりに稼働時間を出し、タイムラインに起動からの帯を描く
    var isAlwaysRunning: Bool {
        schedule.keepAlive && (service?.isRunning ?? false)
    }

    /// 動き続けている常駐ジョブの起動した時刻
    var runningSince: Date? {
        isAlwaysRunning ? processStartDate : nil
    }

    /// 失敗・警告の原因を探すログ。分かれているときは標準エラー（`logFiles` の最後）
    var errorLog: MonitoredItem.LogFile? {
        logFiles.last
    }
}

extension MonitoredItem.LaunchdJob.Origin {
    /// 詳細のジョブの節の1行と、サイドバーの行のツールチップ。サイドバーの絞り込みの選択肢と同じ言葉にする。閲覧のみであることは概要の鍵の行が言うので、ここでは添えない
    var title: String {
        switch self {
        case .userAgent:
            String(localized: "User Agent")

        case .systemAgent:
            String(localized: "System Agent")

        case .daemon:
            String(localized: "Daemon")
        }
    }
}

extension Schedule.Trigger {
    var title: String {
        switch self {
        case .keepAlive:
            String(localized: "Always Running", comment: "Kind of launchd job that launchd keeps running (KeepAlive)")

        case .calendar:
            String(localized: "Calendar", comment: "Kind of launchd job that runs at set times (StartCalendarInterval)")

        case .interval:
            String(localized: "Interval", comment: "Kind of launchd job that runs every N seconds (StartInterval)")

        case .watchPaths:
            String(localized: "File Watch", comment: "Kind of launchd job that runs when a file changes (WatchPaths)")

        case .atLoad:
            String(localized: "At Login", comment: "Kind of launchd job that runs when it is loaded, usually at login (RunAtLoad)")

        case .none:
            String(localized: "No Triggers", comment: "Kind of launchd job without any launch trigger: it only runs when started by another program or by hand")
        }
    }

    /// 色は付けず、形だけで見分ける。状態の色（緑・橙・赤）と取り違えないようにする
    var systemImage: String {
        switch self {
        case .keepAlive:
            "infinity"

        case .calendar:
            "calendar"

        case .interval:
            "timer"

        case .watchPaths:
            "eye"

        case .atLoad:
            "power"

        case .none:
            "hand.tap"
        }
    }
}
