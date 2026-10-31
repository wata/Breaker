import SwiftUI

extension ItemDetailView {
    /**
     状態・前回・次回は概要に出しているので、ここではログとジョブの中身だけを出す。
     節の順番は状態で入れ替えず、毎回同じ場所で探せるようにする。失敗・警告のときは原因を読めるよう標準エラーを選んでおく。
     どの出力もまだ無いときは、「何もない」と言うためだけに節を割かず、ジョブの節の1行にまとめる。
     読み込みを待たずに決め、くるくるや前に選んでいた出力の内容を出さない
     */
    struct LaunchdJobSections: View {
        let job: MonitoredItem.LaunchdJob
        let isAbnormal: Bool
        let edits: [ItemAction]
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
                     選んでいる出力や読み込んだ内容を別のジョブへ持ち越さない。表示中に異常に変わったときも、
                     選択は最初の値しか受け取らないので作り直して標準エラーに切り替える。
                     同じラベルが `~/Library/LaunchAgents` と `/Library/LaunchAgents` にあることがあるので、場所も含めて区別する
                     */
                    .id("\(job.origin)#\(job.label)#\(isAbnormal)")
            }

            Section("Job") {
                ScheduleRow(lines: job.schedule.summaryLines, edits: edits, isLocked: isLocked, perform: perform)

                CommandRow(title: "Program", command: job.programArguments.map(\.abbreviatingHome).joined(separator: " "))

                LabeledContent("Source", value: job.origin.title)

                PathRow(title: "Property List", url: job.plistURL, isLocked: isLocked, perform: perform)

                if let destination = job.plistDestinationURL {
                    PathRow(title: "Link Target", url: destination, isLocked: isLocked, perform: perform)
                }

                if let script = job.scriptURL(home: FileManager.default.homeDirectoryForCurrentUser, fileManager: .default) {
                    PathRow(title: "Script", url: script, isLocked: isLocked, perform: perform)
                }

                if !hasOutput {
                    LabeledContent("Log", value: String(localized: "None", comment: "Shown when there is nothing to show, e.g. no schedule trigger or no log output"))
                }
            }
        }
    }

    /**
     LabeledContent だとボタンの分だけ値の幅が足りず、折り返さずに末尾が切れたので自分で並べる。
     値が1行に収まらないときは、ボタンに詰めて切らずに、値をラベルの下へ回して全文を出す。
     cron の行は、要約と同じことを言う式を別の行にせず、要約の下に等幅で添える（`expression`）
     */
    struct ScheduleRow: View {
        let lines: [String]
        var expression: String?
        let edits: [ItemAction]
        let isLocked: Bool
        let perform: (ItemAction) -> Void

        var body: some View {
            let value = lines.joined(separator: "\n")
            ViewThatFits(in: .horizontal) {
                // 値とボタンが詰まって見えないよう、ほかの行より間を広く取る
                HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                    Text("Schedule")
                        .fixedSize()

                    Spacer(minLength: 0)

                    Value(text: value, expression: expression, alignment: .trailing)
                        .fixedSize()

                    EditButtons(edits: edits, isLocked: isLocked, perform: perform)
                }

                VStack(alignment: .leading, spacing: Spacing.micro) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                        Text("Schedule")

                        Spacer(minLength: Spacing.standard)

                        EditButtons(edits: edits, isLocked: isLocked, perform: perform)
                    }

                    Value(text: value, expression: expression, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    struct Value: View {
        let text: String
        let expression: String?
        let alignment: HorizontalAlignment

        var body: some View {
            VStack(alignment: alignment, spacing: Spacing.hairline) {
                Text(text)
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)

                if let expression {
                    Text(expression)
                        .font(.Mono.regular)
                        .textSelection(.enabled)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    struct EditButtons: View {
        let edits: [ItemAction]
        let isLocked: Bool
        let perform: (ItemAction) -> Void

        var body: some View {
            ForEach(edits) { action in
                Button("Edit…") {
                    perform(action)
                }
                .help(action.title)
                .disabled(isLocked || !action.isEnabled)
            }
        }
    }
}
