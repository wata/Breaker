import Foundation

/**
 終了コードだけでは分からない異常を見つける判定。launchd 以外（cron など）でも使えるよう種類には依らず、
 ファイルの有無・現在時刻・起動時刻・ログの内容は呼び出し側で集めて渡す
 */
enum HealthCheck {
    /// 猶予の下限。launchd はスリープ明けにまとめて走らせるので、起きてすぐの数分は遅れて当然
    static let minimumGrace: TimeInterval = 15 * 60
    /// 間隔に対する猶予の割合。1日1回のジョブなら2時間半ほど待つ
    static let graceRatio = 0.1
    static let logLineCount = 20
    /// 長いエラー行がそのまま副行と通知に出ると読めないので、ここで切る
    static let maxLogErrorLength = 120

    /// 概要の復旧ボタンでログを開くかを、この理由かどうかで見分ける
    static var logErrorReason: String {
        String(localized: "Error in log", comment: "Reason of an item whose log has an error line. The line itself is shown separately")
    }

    /// 直前の終了コードが 0 でも、ログにエラーがあればジョブの仕事は失敗している
    static func logErrorStatus(_ line: String) -> ItemStatus {
        .failed(reason: logErrorReason, note: line)
    }

    enum FileState: Hashable, Sendable {
        case missing
        case file(isExecutable: Bool)
        case directory
    }

    /// 動くために在るべきパス。`kind` で何を確かめるかと、無いときの理由の言い方が決まる
    struct Requirement: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case executable
            case script
            case workingDirectory
            case logDirectory
            case interpreter
        }

        let kind: Kind
        /// `~` を展開した絶対パス
        let path: String
    }

    // MARK: - B. 静的チェック

    /**
     最初に見つかった問題。在るべきパスが無ければジョブは動けないので失敗にし、パスは補足に分ける。
     並べた順に確かめるので、呼び出し側は直す順（起動するもの → 中身 → 周り）に渡す
     */
    static func fileFailure(in requirements: [Requirement], home: URL, state: (String) -> FileState) -> ItemStatus? {
        requirements.compactMap { requirement in
            problem(of: requirement, state: state(requirement.path))
                .map { ItemStatus.failed(reason: $0, note: requirement.path.abbreviatingTilde(home: home)) }
        }
        .first
    }

    /// 概要の復旧ボタンで定義ファイルを見せるかを、`fileFailure` の理由かどうかで見分ける
    static func isFileProblem(_ reason: String) -> Bool {
        FileProblem.allCases.contains { $0.reason == reason }
    }

    private enum FileProblem: CaseIterable {
        case executableNotFound
        case interpreterNotFound
        case notExecutable
        case scriptNotFound
        case workingDirectoryNotFound
        case logFolderNotFound

        var reason: String {
            switch self {
            case .executableNotFound:
                String(localized: "Executable not found")

            case .interpreterNotFound:
                String(localized: "Interpreter not found")

            case .notExecutable:
                String(localized: "Can't be executed")

            case .scriptNotFound:
                String(localized: "Script not found")

            case .workingDirectoryNotFound:
                String(localized: "Working directory not found")

            case .logFolderNotFound:
                String(localized: "Log folder not found")
            }
        }
    }

    private static func problem(of requirement: Requirement, state: FileState) -> String? {
        let problem: FileProblem? = switch (requirement.kind, state) {
        case (.executable, .missing):
            .executableNotFound

        case (.interpreter, .missing):
            .interpreterNotFound

        case (.executable, .directory), (.executable, .file(isExecutable: false)),
             (.interpreter, .directory), (.interpreter, .file(isExecutable: false)):
            .notExecutable

        case (.script, .missing):
            .scriptNotFound

        case (.workingDirectory, .missing), (.workingDirectory, .file):
            .workingDirectoryNotFound

        case (.logDirectory, .missing), (.logDirectory, .file):
            .logFolderNotFound

        case (.executable, .file(isExecutable: true)), (.interpreter, .file(isExecutable: true)),
             (.script, .file), (.script, .directory),
             (.workingDirectory, .directory), (.logDirectory, .directory):
            nil
        }
        return problem?.reason
    }

    static func fileState(atPath path: String, fileManager: FileManager = .default) -> FileState {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        return isDirectory.boolValue ? .directory : .file(isExecutable: fileManager.isExecutableFile(atPath: path))
    }

    // MARK: - A. 走っていない検出

    /**
     走っているはずなのに走っていない予定の時刻。最終実行は、ログの更新時刻と実行を見た時刻の新しいほう（どちらも無ければ nil）。
     見張りを始める前の予定は、走ったかどうかを確かめようがないので数えない（アプリを起動した直後は異常にしない）。
     電源が切れていた間の予定は launchd が走らせないので、起動がその予定より後なら数えない
     */
    static func missedRun(
        schedule: Schedule,
        lastRun: Date?,
        watchStart: Date,
        now: Date,
        bootTime: Date?,
        calendar: Calendar = .current
    ) -> Date? {
        let missed = [
            missedCalendarRun(schedule: schedule, lastRun: lastRun, watchStart: watchStart, now: now, bootTime: bootTime, calendar: calendar),
            missedIntervalRun(schedule: schedule, lastRun: lastRun, watchStart: watchStart, now: now, bootTime: bootTime),
        ]
        return missed.compactMap { $0 }.min()
    }

    /**
     launchd と cron で同じ言い方にする。予定の日時は補足に分ける。
     日時は「今日」「昨日」の言葉にしない。日付が変わると補足の文字が変わり、同じ異常を新しい異常として通知し直してしまうため
     */
    static func missedRunStatus(_ missedRun: Date) -> ItemStatus {
        .failed(
            reason: String(localized: "Didn't run as scheduled", comment: "Reason of a job that didn't run at its scheduled time. The time is shown separately"),
            note: MonitoredItem.format(missedRun)
        )
    }

    static func grace(interval: TimeInterval) -> TimeInterval {
        max(minimumGrace, interval * graceRatio)
    }

    private static func missedCalendarRun(
        schedule: Schedule,
        lastRun: Date?,
        watchStart: Date,
        now: Date,
        bootTime: Date?,
        calendar: Calendar
    ) -> Date? {
        guard
            let previous = schedule.previousRun(atOrBefore: now, calendar: calendar),
            let next = schedule.nextRun(after: previous, lastRun: nil, calendar: calendar),
            watchStart < previous,
            previous.addingTimeInterval(grace(interval: next.timeIntervalSince(previous))) < now,
            lastRun.map({ $0 < previous }) ?? true,
            bootTime.map({ $0 <= previous }) ?? true
        else {
            return nil
        }
        return previous
    }

    /**
     最終実行・起動・見張り開始のいちばん遅い時刻から数える。StartInterval の時計は launchd がジョブを読み込んだとき
     （ログイン時）から回り直し、見張りを始める前の予定は数えないため
     */
    private static func missedIntervalRun(schedule: Schedule, lastRun: Date?, watchStart: Date, now: Date, bootTime: Date?) -> Date? {
        guard
            let interval = schedule.interval,
            interval > 0
        else {
            return nil
        }
        let start = [lastRun, bootTime, watchStart].compactMap { $0 }.max() ?? watchStart
        let due = start.addingTimeInterval(TimeInterval(interval))
        return due.addingTimeInterval(grace(interval: TimeInterval(interval))) < now ? due : nil
    }

    // MARK: - C. ログのエラー

    /// 渡した順（標準エラー → 標準出力）に、それぞれ最後の `logLineCount` 行から最後のエラー行を探す
    static func logError(in logs: [String]) -> String? {
        logs.lazy
            .compactMap { LogErrorLine.last(in: LogReader.lastLines(of: $0, count: logLineCount)) }
            .first
            .map { $0.count > maxLogErrorLength ? String($0.prefix(maxLogErrorLength)) + "…" : $0 }
    }
}
