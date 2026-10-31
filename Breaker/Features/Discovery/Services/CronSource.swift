import Foundation

struct CronError: LocalizedError {
    let status: Int32
    let message: String

    var errorDescription: String? {
        String(localized: "Couldn't read crontab (exit code \(status)): \(message)")
    }
}

/**
 `crontab -l` の行。読むだけで、編集や停止はしない。cron が動いているかは調べない（macOS の cron は launchd が必要なときに起動する）。
 cron は実行の記録を持たないので、走っていない（A）とログのエラー（C）はリダイレクト先のログが分かるときだけ見る。
 スリープ中に過ぎた予定は起きてからも走らないことがある（夜中の予定がある MacBook で毎朝異常になる）ので、A は予定の時刻に Mac が起きていたときだけ出す
 */
struct CronSource: ItemSource {
    let kind = MonitoredItem.Kind.cronJob

    private let shell: any ShellRunning
    private let homeDirectory: URL
    private let bootTime: @Sendable () -> Date?
    /// `pmset -g log` は重いので、取り直しをまたいで覚える。同じ Source を使い続けたときだけ読み直しを減らせる
    private let awakeHistory: AwakeHistory

    init(
        shell: any ShellRunning = ShellRunner(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bootTime: @escaping @Sendable () -> Date? = BootTime.current,
        awakeHistory: AwakeHistory = AwakeHistory()
    ) {
        self.shell = shell
        self.homeDirectory = homeDirectory
        self.bootTime = bootTime
        self.awakeHistory = awakeHistory
    }

    func items() async throws -> [MonitoredItem] {
        let output = try await shell.run("/usr/bin/crontab", arguments: ["-l"])
        guard let text = try Self.crontab(from: output) else {
            return []
        }
        let now = Date.now
        let bootTime = bootTime()
        var occurrences: [String: Int] = [:]
        var items: [MonitoredItem] = []
        for entry in Crontab.parse(text) {
            // 同じ行が並んでも ID が重ならないよう、何番目の同じ行かを添える
            let occurrence = occurrences[entry.line, default: 0]
            occurrences[entry.line] = occurrence + 1
            items.append(await item(for: entry, key: "\(entry.line)#\(occurrence)", now: now, bootTime: bootTime))
        }
        return items
    }

    /// crontab が無いと終了コード 1 で "no crontab for <user>" を返す。これは空の crontab として nil にする
    static func crontab(from output: ShellOutput) throws -> String? {
        if output.status == 0 {
            return output.stdout
        }
        if output.stderr.contains("no crontab for") {
            return nil
        }
        throw CronError(status: output.status, message: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func item(for entry: Crontab.Entry, key: String, now: Date, bootTime: Date?) async -> MonitoredItem {
        guard let job = entry.job else {
            let detail = MonitoredItem.CronJob(
                line: entry.line,
                expression: nil,
                command: nil,
                schedule: nil,
                isReboot: false,
                standardOutPath: nil,
                standardErrorPath: nil,
                lastRun: nil,
                firstPath: nil
            )
            return MonitoredItem(key: key, name: Self.name(of: entry.line, command: nil), status: Self.unparsableStatus, detail: .cronJob(detail))
        }
        let command = CronCommand(job.command, home: homeDirectory)
        let schedule: Schedule? = switch job.timing {
        case .reboot:
            nil

        case .fields(let fields):
            fields.schedule
        }
        // 標準出力と標準エラーを同じファイルに出す行は1回だけ読む。原因は標準エラーに出ることが多いので先に見る
        let logPaths = [command.standardErrorPath, command.standardOutPath].compactMap { $0 }.uniqued()
        let lastRun = LogReader.lastModificationDate(of: logPaths)
        let fileFailure = HealthCheck.fileFailure(in: Self.requirements(of: command), home: homeDirectory) { HealthCheck.fileState(atPath: $0) }
        let missedRun = await awakeMissedRun(Self.missedRun(schedule: schedule, lastRun: lastRun, now: now, bootTime: bootTime), now: now)
        // ログを読むのは C を出しうるとき（ほかに問題が無く、ログがある）だけにする
        let logError = fileFailure == nil && missedRun == nil && lastRun != nil
            ? HealthCheck.logError(in: await LogReader.tails(of: logPaths, lineCount: HealthCheck.logLineCount))
            : nil
        let detail = MonitoredItem.CronJob(
            line: entry.line,
            expression: job.expression,
            command: job.command,
            schedule: schedule,
            isReboot: job.timing == .reboot,
            standardOutPath: command.standardOutPath,
            standardErrorPath: command.standardErrorPath,
            lastRun: lastRun,
            firstPath: command.resolvedFirstPath
        )
        return MonitoredItem(
            key: key,
            name: Self.name(of: job.command, command: command),
            status: Self.status(fileFailure: fileFailure, missedRun: missedRun, logError: logError),
            detail: .cronJob(detail),
            // launchd と同じく、用途の説明はホームにある利用者のスクリプトからだけ読む（`/usr/bin/python3` などは見ない）
            autoDescription: command.resolvedFirstPath.flatMap { path in
                path.isPath(under: homeDirectory.path(percentEncoded: false)) && FileManager.default.fileExists(atPath: path)
                    ? ItemDescriptionReader.description(forScriptAt: URL(filePath: path), home: homeDirectory)
                    : nil
            }
        )
    }

    /// 候補があるときだけ電源の履歴を見る（ほとんどの取り直しでは `pmset` を走らせない）
    private func awakeMissedRun(_ candidate: Date?, now: Date) async -> Date? {
        guard let candidate else {
            return nil
        }
        return await awakeHistory.wasAwake(at: candidate, for: Self.minimumAwakeDuration, now: now) ? candidate : nil
    }
}

extension CronSource {
    static let unparsableStatus = ItemStatus.warning(reason: String(localized: "Can't parse this line"))
    /// 名前に使うコマンドの先頭の長さ。パスが無いコマンドでもサイドバーの1行に収まるくらい
    static let maxNameLength = 40
    /**
     予定の時刻からこれだけ起き続けていたら、cron が走らせてジョブがログに書くはずだとみなす。cron は毎分起きて予定を見るので数分あれば走り出すが、
     リダイレクト先の更新時刻は書き込むまで変わらないため、少し長めにとる。
     `HealthCheck.minimumGrace`（15 分）より短くしておくと、走っていない候補が出た時点の電源の履歴1回で必ず答えられる
     */
    static let minimumAwakeDuration: TimeInterval = 10 * 60

    /// コマンドの最初のパスの最後の要素（`~/bin/backup.sh` なら `backup.sh`）。取れなければコマンドの先頭
    static func name(of text: String, command: CronCommand?) -> String {
        let fileName = command?.firstPath.map { ($0 as NSString).lastPathComponent } ?? ""
        return fileName.isEmpty || fileName == "/" ? String(text.prefix(maxNameLength)) : fileName
    }

    /// 起動するもの → ログのフォルダの順（直す順）
    static func requirements(of command: CronCommand) -> [HealthCheck.Requirement] {
        let logDirectories = [command.standardOutPath, command.standardErrorPath]
            .compactMap { $0.map { ($0 as NSString).deletingLastPathComponent } }
            .uniqued()
        return [command.executable.map { HealthCheck.Requirement(kind: .executable, path: $0) }].compactMap { $0 }
            + logDirectories.map { HealthCheck.Requirement(kind: .logDirectory, path: $0) }
    }

    /**
     ログの更新時刻だけで判定する。cron には launchd の runs のような実行の記録が無いので、見張りを始めた時刻は区切らない
     （ログは Breaker の起動前の実行も残している）。誤検知を避けるため、ログが一度も書かれていない（ファイルが無い）ときは出さない。
     これは候補で、その時刻に Mac が起きていたかは `awakeMissedRun` で確かめる
     */
    static func missedRun(schedule: Schedule?, lastRun: Date?, now: Date, bootTime: Date?) -> Date? {
        guard
            let schedule,
            let lastRun
        else {
            return nil
        }
        return HealthCheck.missedRun(schedule: schedule, lastRun: lastRun, watchStart: .distantPast, now: now, bootTime: bootTime)
    }

    /// launchd と同じ優先順。どれもジョブの仕事ができていないので失敗にする
    static func status(fileFailure: ItemStatus?, missedRun: Date?, logError: String?) -> ItemStatus {
        if let fileFailure {
            return fileFailure
        }
        if let missedRun {
            return HealthCheck.missedRunStatus(missedRun)
        }
        if let logError {
            return HealthCheck.logErrorStatus(logError)
        }
        return .ok
    }
}
