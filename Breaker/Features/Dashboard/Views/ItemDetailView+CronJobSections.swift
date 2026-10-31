import SwiftUI

/**
 launchd ジョブの節と同じ並び（ログ → 中身）にそろえる。cron の行は編集できないので、スケジュールに「編集…」は出さない。
 ログの出し方は `LaunchdJobSections` と同じ
 */
extension ItemDetailView {
    struct CronJobSections: View {
        let job: MonitoredItem.CronJob
        let isAbnormal: Bool
        let isLocked: Bool
        let refreshDate: Date?
        let perform: (ItemAction) -> Void

        var body: some View {
            let logs = job.logFiles
            let hasOutput = logs.contains { $0.hasOutput() }

            if
                hasOutput,
                let log = isAbnormal ? job.errorLog : logs.first
            {
                LogTailView(logs: logs, selection: log, refreshDate: refreshDate, isLocked: isLocked, perform: perform)
                    /**
                     選んでいる出力や読み込んだ内容を別の行へ持ち越さない。表示中に異常に変わったときも、
                     選択は最初の値しか受け取らないので作り直して標準エラーに切り替える
                     */
                    .id("\(job.line)#\(isAbnormal)")
            }

            // launchd ジョブと同じ見出しにそろえる
            Section("Job") {
                ScheduleRow(lines: job.summaryLines, expression: job.summaryExpression, edits: [], isLocked: isLocked, perform: perform)

                if let command = job.command {
                    CommandRow(title: "Command", command: command)
                } else {
                    CommandRow(title: "crontab Line", command: job.line)
                }

                if let script = job.scriptURL(fileManager: .default) {
                    PathRow(title: "Script", url: script, isLocked: isLocked, perform: perform)
                }

                if !hasOutput {
                    LabeledContent(
                        "Log",
                        value: logs.isEmpty
                            ? String(localized: "Not redirected")
                            : String(localized: "None", comment: "Shown when there is nothing to show, e.g. no schedule trigger or no log output")
                    )
                }
            }
        }
    }
}
