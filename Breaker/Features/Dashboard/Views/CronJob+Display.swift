import Foundation

extension MonitoredItem.CronJob {
    /// 既存の要約は値の組み合わせごとに1行なので、これより多いと読めない。そのときは cron の式そのものを出す
    static let maxSummaryLines = 4

    /// 詳細ペインのスケジュールの行。`Schedule` に直せるものは launchd と同じ要約にする
    var summaryLines: [String] {
        if isReboot {
            return [String(localized: "When cron starts (@reboot)")]
        }
        if
            let lines = schedule?.summaryLines,
            lines.count <= Self.maxSummaryLines
        {
            return lines
        }
        return [expression ?? String(localized: "Can't parse")]
    }

    /// スケジュールの要約に添える cron の式。要約が式そのもの・`@reboot` を含む文のときは同じことを二度言わないので nil
    var summaryExpression: String? {
        guard
            let expression,
            !isReboot,
            !summaryLines.contains(expression)
        else {
            return nil
        }
        return expression
    }

    var logFiles: [MonitoredItem.LogFile] {
        MonitoredItem.LogFile.files(standardOutPath: standardOutPath, standardErrorPath: standardErrorPath)
    }

    /// 分かれているときは標準エラー（`logFiles` の最後）
    var errorLog: MonitoredItem.LogFile? {
        logFiles.last
    }

    /// コマンドの最初のパスが実在するファイルなら、そのスクリプト。`cd ~/dev/x && …` のフォルダは開けないので含めない
    func scriptURL(fileManager: FileManager) -> URL? {
        var isDirectory: ObjCBool = false
        guard
            let firstPath,
            fileManager.fileExists(atPath: firstPath, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            return nil
        }
        return URL(filePath: firstPath)
    }
}
