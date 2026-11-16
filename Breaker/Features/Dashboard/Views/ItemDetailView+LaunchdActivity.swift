import SwiftUI

extension ItemDetailView {
    /**
     launchd ジョブの動きを図で見せる。主役は次回までの残り時間の大きな数字1つで、実行回数と前回の終了はその下の小さな1行にまとめる
     （失敗の見出しより目立たせないため。利用者の判断）。その下のタイムラインに、予定・前回・走らなかった予定・今を並べる。
     タイムラインに印で出した前回・次回は、概要の文から外す（`MonitoredItem.headerRunSummary(now:)`）。
     右上にジョブの種類（時刻指定・間隔・常駐など）を記号だけで添える（比較した中から利用者が選んだ、いちばん静かな見せ方）
     */
    struct LaunchdActivitySection: View {
        let job: MonitoredItem.LaunchdJob
        let status: ItemStatus

        var body: some View {
            // 線を出さないのは止めているジョブだけなので、止めていて読み込まれてもいない（回数も無い）ときだけ空の節を出さない
            if
                job.service != nil
                    || !status.isInactive
            {
                Section {
                    // 残り時間と「今」の位置が古びないよう、分が変わるたびに描き直す
                    TimelineView(.everyMinute) { context in
                        VStack(alignment: .leading, spacing: Spacing.standard) {
                            HStack(alignment: .top, spacing: Spacing.standard) {
                                VStack(alignment: .leading, spacing: Spacing.hairline) {
                                    // 予定のあるジョブは次回までの残り、動き続けている常駐ジョブは起動からの稼働時間を主役にする
                                    let figure = RunTimeline.nextRun(of: job, status: status, now: context.date).map { nextRun in
                                        DurationFigure(
                                            title: String(localized: "Until Next Run", comment: "Title of the countdown to the next run of a launchd job in the detail"),
                                            from: context.date,
                                            to: nextRun
                                        )
                                    }
                                        ?? job.runningSince.map { since in
                                            DurationFigure(
                                                title: String(localized: "Uptime", comment: "Title of how long a launchd job that launchd keeps running has been running, in the detail"),
                                                from: since,
                                                to: context.date
                                            )
                                        }
                                    if let figure {
                                        figure
                                    }

                                    if let service = job.service {
                                        Text(Self.serviceSummary(of: service))
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                TriggerSymbols(triggers: job.schedule.triggers)
                            }

                            if let timeline = RunTimeline(job: job, status: status, now: context.date) {
                                TimelineStrip(timeline: timeline, status: status)
                            }
                        }
                        .padding(.vertical, Spacing.micro)
                    }
                }
            }
        }

        /**
         `58 回実行（読み込み後） · 終了コード 1`。終了コードは失敗したときだけ添える。0 は概要の「正常」と線の ✓ が言うので繰り返さない（利用者の判断）。
         まだ一度も終了していなければ終了の部分を出さない
         */
        nonisolated static func serviceSummary(of service: LaunchdServiceInfo, locale: Locale = .current) -> String {
            let exit: String? = switch service.lastExit {
            case .code(0), .never:
                nil

            case .code(let code):
                String(localized: "Exit code \(code)", language: locale)

            case .signal(let signal):
                String(localized: LocalizedStringResource("Ended by \(signalName(signal))", comment: "Last exit of a launchd job that was ended by a signal, e.g. Ended by SIGTERM"), language: locale)
            }
            return [
                String(localized: LocalizedStringResource("\(service.runs) runs since loaded", comment: "Number of times a launchd job has run since launchd loaded it"), language: locale),
                exit,
            ]
            .compactMap { $0 }
            .joined(separator: " · ")
        }

        /// 終了させたシグナルの名前。よく見るものだけ名前にし、ほかは番号のまま出す
        nonisolated static func signalName(_ signal: Int32) -> String {
            let names: [Int32: String] = [
                SIGHUP: "SIGHUP",
                SIGINT: "SIGINT",
                SIGABRT: "SIGABRT",
                SIGKILL: "SIGKILL",
                SIGBUS: "SIGBUS",
                SIGSEGV: "SIGSEGV",
                SIGTERM: "SIGTERM",
            ]
            return names[signal] ?? "\(signal)"
        }
    }

    /// ジョブの種類の記号。色は付けず形だけで見分け、名前はポインタを載せたときと読み上げで伝える
    struct TriggerSymbols: View {
        let triggers: [Schedule.Trigger]

        var body: some View {
            HStack(spacing: Spacing.tight) {
                ForEach(triggers, id: \.self) { trigger in
                    Image(systemName: trigger.systemImage)
                        .help(trigger.title)
                        .accessibilityLabel(trigger.title)
                }
            }
            .font(.Body.regular)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    /// 次回までの残り・常駐ジョブの稼働時間の大きな数字。数字を大きく、単位（「時間」「分」）を小さく二次色で組み、数字だけが目に入るようにする
    struct DurationFigure: View {
        let title: String
        let from: Date
        let to: Date

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(title)
                    .foregroundStyle(.secondary)

                Text(Self.emphasizingDigits(of: Self.durationText(from: from, to: to)))
                    .textSelection(.enabled)
            }
            // 画面の「3h 12m」の略記は読み上げで分かりにくいので、読み上げには略さない書き方を渡す（ネットワークの速度の数字と同じ組み方）
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(Self.durationText(from: from, to: to, width: .wide))
        }

        /// `3h 12m`。1分未満は「0分」と言わず1分にする（分ごとに描き直すので、0分のまま次回を迎えない。起動直後も1分から数える）
        nonisolated static func durationText(from: Date, to: Date, width: Duration.UnitsFormatStyle.UnitWidth = .narrow, locale: Locale = .current) -> String {
            let seconds = max(to.timeIntervalSince(from), 60)
            var style = Duration.UnitsFormatStyle(
                allowedUnits: [.days, .hours, .minutes],
                width: width,
                maximumUnitCount: 2,
                fractionalPart: .hide(rounded: .down)
            )
            style.locale = locale
            return Duration.seconds(seconds).formatted(style)
        }

        nonisolated static func emphasizingDigits(of value: String) -> AttributedString {
            value.reduce(into: AttributedString()) { text, character in
                var piece = AttributedString(String(character))
                if character.isNumber {
                    piece.font = .Display.value
                } else {
                    piece.font = .Display.unit
                    piece.foregroundColor = .secondary
                }
                text += piece
            }
        }
    }
}

extension MonitoredItem {
    /**
     概要に出す前回・次回の文。launchd ジョブは、詳細のタイムラインに印で出した前回・次回を文から外す（同じことを二度言わない。利用者の判断）。
     印にならないもの（範囲より古い前回、止めているジョブの前回など）は、日時が読めなくならないよう文に残す。
     動き続けている常駐ジョブの前回はログを書いた時刻で、起動からずっと動いている帯と食い違って見えるので出さない
     */
    func headerRunSummary(now: Date) -> String? {
        guard
            case .launchdJob(let job) = detail,
            let timeline = ItemDetailView.RunTimeline(job: job, status: status, now: now),
            let dates = runDates(now: now)
        else {
            return runSummary(now: now, lastRunStyle: .absolute)
        }
        return Self.runSummary(
            lastRun: timeline.lastRun == nil && !timeline.isAlwaysRunning ? dates.last : nil,
            nextRun: timeline.nextRun == nil ? dates.next : nil,
            lastRunStyle: .absolute,
            now: now
        )
    }
}
