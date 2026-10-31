import Foundation

/// launchd ジョブと cron の行で共有する、ログと前回・次回の出し方
extension MonitoredItem {
    struct LogFile: Hashable {
        enum Kind: Hashable {
            /// 標準出力と標準エラーを同じファイルに出している。出力の種類を言えないので「ログ」と呼ぶ
            case combined
            case standardOutput
            case standardError
        }

        let kind: Kind
        let path: String

        var title: String {
            switch kind {
            case .combined:
                String(localized: "Log", comment: "Log file that holds both standard output and standard error")

            case .standardOutput:
                String(localized: "Standard Output")

            case .standardError:
                String(localized: "Standard Error")
            }
        }

        /// 語順が言語で違うので、出力の名前を差し込まず、操作ごとに文を持つ
        var openActionTitle: String {
            switch kind {
            case .combined:
                String(localized: "Open Log")

            case .standardOutput:
                String(localized: "Open Standard Output Log")

            case .standardError:
                String(localized: "Open Standard Error Log")
            }
        }

        var revealActionTitle: String {
            switch kind {
            case .combined:
                String(localized: "Show Log in Finder")

            case .standardOutput:
                String(localized: "Show Standard Output Log in Finder")

            case .standardError:
                String(localized: "Show Standard Error Log in Finder")
            }
        }

        /// 無いファイルも空のファイルも「まだ出力がない」として同じに扱う
        func hasOutput(fileManager: FileManager = .default) -> Bool {
            let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int
            return (size ?? 0) > 0
        }

        /// 標準出力と標準エラーを同じファイルに出すことが多いので、同じなら1つにまとめる。そのときは出力の種類を言えないので「ログ」と呼ぶ
        static func files(standardOutPath: String?, standardErrorPath: String?) -> [LogFile] {
            switch (standardOutPath, standardErrorPath) {
            case (let standardOutPath?, let standardErrorPath?) where standardOutPath != standardErrorPath:
                [LogFile(kind: .standardOutput, path: standardOutPath), LogFile(kind: .standardError, path: standardErrorPath)]

            case (let path?, _), (nil, let path?):
                [LogFile(kind: .combined, path: path)]

            case (nil, nil):
                []
            }
        }
    }

    enum RunDateStyle {
        /// サイドバーの行は狭いので、前回を「3 日前」のように短く出す
        case relative
        /// 詳細ヘッダーでは前回も次回と同じ絶対日時にそろえる
        case absolute
    }

    /// 失敗・警告の原因を探すログ。ログの無い種類は nil
    var errorLog: LogFile? {
        switch detail {
        case .launchdJob(let job):
            job.errorLog

        case .cronJob(let job):
            job.errorLog

        case .folderAction, .swiftBarPlugin, .monitoredApp, .sourceFailure:
            nil
        }
    }

    /**
     予定で動く種類（launchd ジョブと cron）の前回と次回。予定で動かない種類は nil。
     止めている launchd ジョブには次回がない。cron の行は止められないので、次回はいつも出す
     */
    func runDates(now: Date) -> (last: Date?, next: Date?)? {
        switch detail {
        case .launchdJob(let job):
            (job.lastRun, status.isInactive ? nil : job.schedule.nextRun(after: now, lastRun: job.lastRun))

        case .cronJob(let job):
            (job.lastRun, job.schedule?.nextRun(after: now, lastRun: nil))

        case .folderAction, .swiftBarPlugin, .monitoredApp, .sourceFailure:
            nil
        }
    }

    /// 詳細の概要に出す前回・次回
    func runSummary(now: Date, lastRunStyle: RunDateStyle = .relative) -> String? {
        runDates(now: now).flatMap { Self.runSummary(lastRun: $0.last, nextRun: $0.next, lastRunStyle: lastRunStyle, now: now) }
    }

    static func runSummary(
        lastRun: Date?,
        nextRun: Date?,
        lastRunStyle: RunDateStyle,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        let parts = [
            lastRun.map { lastRunText($0, style: lastRunStyle, now: now, calendar: calendar, locale: locale) },
            nextRun.map { nextRunText($0, now: now, calendar: calendar, locale: locale) },
        ]
        .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /**
     「前回 …」。英語ではラベルの後の値を、文頭と同じ大文字始まりにそろえる（相対の「Yesterday」も、次回の「Tomorrow 9:00 AM」と同じ書き方にする）
     */
    static func lastRunText(_ date: Date, style: RunDateStyle, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let text = switch style {
        case .relative:
            Date.AnchoredRelativeFormatStyle(
                anchor: date,
                presentation: .named,
                unitsStyle: .abbreviated,
                locale: locale,
                calendar: calendar,
                capitalizationContext: .beginningOfSentence
            )
            .format(now)

        case .absolute:
            formatRunDate(date, now: now, calendar: calendar, locale: locale)
        }
        return String(localized: "Last: \(text)", language: locale)
    }

    static func nextRunText(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        String(localized: "Next: \(formatRunDate(date, now: now, calendar: calendar, locale: locale))", language: locale)
    }

    /**
     前回・次回の日時。人が言うのと同じく、昨日・今日・明日は曜日と日付の代わりに言葉で言う（「今日 11:00」）。
     それ以外は `format` と同じ。時刻の書き方と言葉は `locale` に従う
     */
    static func formatRunDate(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
        let dayOffset = [-1, 0, 1].first { offset in
            calendar.date(byAdding: .day, value: offset, to: now).map { calendar.isDate(date, inSameDayAs: $0) } ?? false
        }
        switch dayOffset {
        case -1:
            return String(localized: "Yesterday \(time)", language: locale)

        case 0:
            return String(localized: "Today \(time)", language: locale)

        case 1:
            return String(localized: "Tomorrow \(time)", language: locale)

        default:
            return format(date, calendar: calendar, locale: locale)
        }
    }

    /// 前回・次回と、走っていない予定の日時の書き方
    static func format(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.defaultDigits).day().weekday(.abbreviated).hour().minute()
        )
    }
}
