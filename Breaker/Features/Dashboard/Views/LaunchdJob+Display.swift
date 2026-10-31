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
