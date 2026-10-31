import Foundation

/// プレビュー用。すべての種類と状態（検出の失敗を含む）を1つずつ以上含める
extension MonitoredItem {
    static let samples: [MonitoredItem] = [
        launchdJob(
            "com.example.cert-check",
            status: .ok,
            schedule: Schedule(calendarEntries: [.init(minute: 0, hour: 11, day: 1)]),
            service: .init(state: "not running", pid: nil, runs: 3, lastExit: .code(0)),
            lastRun: .now.addingTimeInterval(-3 * 86400),
            autoDescription: "Checks when the server certificate expires and sends a notification if fewer than 30 days remain"
        ),
        launchdJob(
            "com.example.calendar-sync",
            status: .running,
            schedule: Schedule(runAtLoad: true, keepAlive: true),
            service: .init(state: "running", pid: 812, runs: 1, lastExit: .never),
            lastRun: .now.addingTimeInterval(-600),
            autoDescription: "Calendar Sync: fetches events from a shared calendar and writes them to an ICS file"
        ),
        launchdJob(
            "com.example.daily-sales-report",
            status: .failed(reason: String(localized: "Exit code \(Int32(1))")),
            schedule: Schedule(calendarEntries: (1...5).map { .init(minute: 0, hour: 9, weekday: $0) }),
            service: .init(state: "not running", pid: nil, runs: 58, lastExit: .code(1)),
            lastRun: .now.addingTimeInterval(-26 * 3600)
        ),
        launchdJob(
            "com.example.photo-import",
            status: .failed(reason: String(localized: "Not loaded")),
            schedule: Schedule(watchPaths: ["~/Pictures/Import"]),
            service: nil,
            lastRun: nil
        ),
        launchdJob(
            "com.example.price-watch",
            status: .inactive(reason: LaunchAgentSource.disabledReason, note: ".plist.disabled"),
            schedule: Schedule(interval: 1800),
            service: nil,
            lastRun: .now.addingTimeInterval(-40 * 86400),
            isDisabledFile: true,
            autoDescription: "Checks whether items on a wish list have dropped in price"
        ),
        // 走っていない（A）。ログの更新時刻が前回の予定より古い
        launchdJob(
            "com.example.photo-backup",
            status: HealthCheck.missedRunStatus(samplePreviousBackup),
            schedule: sampleBackupSchedule,
            service: .init(state: "not running", pid: nil, runs: 4, lastExit: .code(0)),
            lastRun: samplePreviousBackup.addingTimeInterval(-86400 + 120)
        ),
        // 静的チェック（B）。まだ走っていなくても、次に走るときに失敗するので失敗
        launchdJob(
            "com.example.feed-digest",
            status: .failed(reason: String(localized: "Script not found"), note: "~/dev/scripts/com.example.feed-digest.py"),
            schedule: Schedule(interval: 3600),
            service: .init(state: "not running", pid: nil, runs: 0, lastExit: .never),
            lastRun: nil
        ),
        sampleLogError,
        // アプリが入れたジョブ（ホームのジョブではない）。異常でも通知・バッジ・件数には数えない
        launchdJob(
            "com.example.updater",
            status: .failed(reason: String(localized: "Exit code \(Int32(1))")),
            schedule: Schedule(interval: 3600),
            service: .init(state: "not running", pid: nil, runs: 12, lastExit: .code(1)),
            lastRun: nil,
            isHomeJob: false
        ),
        cronJob(
            "30 7 * * 1-5",
            command: "/Users/me/bin/sync-notes.sh >> /Users/me/Library/Logs/sync-notes.log 2>&1",
            status: .ok,
            schedule: sampleCronSchedule,
            standardOutPath: "/Users/me/Library/Logs/sync-notes.log",
            standardErrorPath: "/Users/me/Library/Logs/sync-notes.log",
            lastRun: .now.addingTimeInterval(-5 * 3600)
        ),
        // 静的チェック（B）。リダイレクト先のフォルダが無い
        cronJob(
            "0 * * * *",
            command: "/Users/me/bin/fetch-feeds.py > /Users/me/logs/feeds.log 2> /Users/me/logs/feeds.err.log",
            status: .failed(reason: String(localized: "Log folder not found"), note: "~/logs"),
            schedule: Schedule(calendarEntries: [.init(minute: 0)]),
            standardOutPath: "/Users/me/logs/feeds.log",
            standardErrorPath: "/Users/me/logs/feeds.err.log",
            lastRun: nil
        ),
        MonitoredItem(
            key: "/Users/me/Downloads",
            name: "Downloads",
            status: .ok,
            detail: .folderAction(.init(
                folderURL: URL(filePath: "/Users/me/Downloads", directoryHint: .isDirectory),
                scriptNames: ["rename-screenshots.scpt"],
                isEnabled: true
            ))
        ),
        MonitoredItem(
            key: "/Volumes/share1/scan",
            name: "scan",
            status: FolderActionSource.missingFolderStatus,
            detail: .folderAction(.init(
                folderURL: URL(filePath: "/Volumes/share1/scan", directoryHint: .isDirectory),
                scriptNames: ["import-scan.scpt", "notify.scpt"],
                isEnabled: true
            ))
        ),
        sampleSourceFailure,
        MonitoredItem(
            key: "com.example.FeedReader",
            name: "FeedReader",
            status: .running,
            detail: .monitoredApp(.init(bundleID: "com.example.FeedReader", appURL: URL(filePath: "/Applications/FeedReader.app"), isRunning: true))
        ),
        MonitoredItem(
            key: "com.example.AudioPin",
            name: "AudioPin",
            status: .warning(reason: String(localized: "Running from outside /Applications"), note: "/Users/me/Developer/AudioPin/build/Release/AudioPin.app"),
            detail: .monitoredApp(.init(
                bundleID: "com.example.AudioPin",
                appURL: URL(filePath: "/Users/me/Developer/AudioPin/build/Release/AudioPin.app"),
                isRunning: true
            ))
        ),
        MonitoredItem(
            key: "com.example.ClipboardKeeper",
            name: "ClipboardKeeper",
            status: .inactive(reason: String(localized: "Not running", comment: "Reason shown for a monitored app that isn't running")),
            detail: .monitoredApp(.init(bundleID: "com.example.ClipboardKeeper", appURL: URL(filePath: "/Applications/ClipboardKeeper.app"), isRunning: false))
        ),
    ]

    private static let sampleCronSchedule = Schedule(calendarEntries: (1...5).map { .init(minute: 30, hour: 7, weekday: $0) })

    /// cron の詳細でログの節を見るための見本。ログは一時フォルダに書く
    static var sampleCronWithLogs: MonitoredItem {
        let log = previewLog(
            named: "sync-notes.log",
            text: ["2026-10-30 07:30:01 sync-notes: synced 12 notes", "2026-10-31 07:30:02 sync-notes: synced 3 notes"].joined(separator: "\n")
        )
        return cronJob(
            "30 7 * * 1-5",
            command: "/Users/me/bin/sync-notes.sh >> ~/Library/Logs/sync-notes.log 2>&1",
            status: .ok,
            schedule: sampleCronSchedule,
            standardOutPath: log.path(percentEncoded: false),
            standardErrorPath: log.path(percentEncoded: false),
            lastRun: .now.addingTimeInterval(-5 * 3600)
        )
    }

    private static func cronJob(
        _ expression: String,
        command: String,
        status: ItemStatus,
        schedule: Schedule,
        standardOutPath: String?,
        standardErrorPath: String?,
        lastRun: Date?
    ) -> MonitoredItem {
        let line = "\(expression) \(command)"
        let firstPath = command.split(separator: " ").first.map(String.init)
        let detail = CronJob(
            line: line,
            expression: expression,
            command: command,
            schedule: schedule,
            isReboot: false,
            standardOutPath: standardOutPath,
            standardErrorPath: standardErrorPath,
            lastRun: lastRun,
            firstPath: firstPath
        )
        let name = firstPath.map { ($0 as NSString).lastPathComponent } ?? line
        return MonitoredItem(key: "\(line)#0", name: name, status: status, detail: .cronJob(detail))
    }

    private static let sampleBackupSchedule = Schedule(calendarEntries: [.init(minute: 30, hour: 3)])
    private static let samplePreviousBackup = sampleBackupSchedule.previousRun(atOrBefore: .now) ?? .now

    static let sampleLogErrorLine = "imaplib.error: [AUTHENTICATIONFAILED] Invalid credentials (Failure)"

    /// ログのエラー（C）。終了コードは 0
    static let sampleLogError = launchdJob(
        "com.example.mail-cleanup",
        status: HealthCheck.logErrorStatus(sampleLogErrorLine),
        schedule: Schedule(calendarEntries: [.init(minute: 0, hour: 7)]),
        service: .init(state: "not running", pid: nil, runs: 12, lastExit: .code(0)),
        lastRun: .now.addingTimeInterval(-3600)
    )

    /// ログのエラーの詳細で、理由と同じ行が概要に二重に出ないことを見るための見本。ログは一時フォルダに書く
    static var sampleLogErrorWithLogs: MonitoredItem {
        let err = previewLog(
            named: "mail-cleanup.err.log",
            text: ["Traceback (most recent call last):", "  File \"/Users/me/dev/scripts/mail-cleanup.py\", line 12", sampleLogErrorLine]
                .joined(separator: "\n")
        )
        let job = LaunchdJob.sample(
            "com.example.mail-cleanup",
            schedule: Schedule(calendarEntries: [.init(minute: 0, hour: 7)]),
            service: .init(state: "not running", pid: nil, runs: 12, lastExit: .code(0)),
            lastRun: .now.addingTimeInterval(-3600),
            standardErrorPath: err.path(percentEncoded: false)
        )
        return MonitoredItem(key: job.label, name: job.label, status: sampleLogError.status, detail: .launchdJob(job))
    }

    /// `/Library/LaunchDaemons` の閲覧のみのジョブ。操作のボタンが無効になり、スケジュールの編集が出ないことを見る
    static var sampleSystemDaemon: MonitoredItem {
        let job = LaunchdJob.sample(
            "com.example.helper",
            schedule: Schedule(interval: 3600),
            service: .init(state: "not running", pid: nil, runs: 35, lastExit: .code(0)),
            isHomeJob: false,
            origin: .daemon
        )
        return MonitoredItem(key: "/\(job.origin.relativePath)/\(job.label)", name: job.label, status: .ok, detail: .launchdJob(job))
    }

    /// 一覧では検出失敗と並べられないので、SwiftBar プラグインの詳細は別に用意する
    static let sampleSwiftBarPlugin = MonitoredItem(
        key: "/Users/me/SwiftBar/battery.5m.sh",
        name: "battery.5m.sh",
        status: .ok,
        detail: .swiftBarPlugin(.init(fileURL: URL(filePath: "/Users/me/SwiftBar/battery.5m.sh"), refreshInterval: 300))
    )

    static let sampleSourceFailure = ItemDiscovery.sourceFailure(
        of: .swiftBarPlugin,
        message: SwiftBarError(message: "Domain com.ameba.SwiftBar does not exist").localizedDescription
    )

    static let sampleLogText = ((1...200).map { "2026-10-29 09:00:\(String(format: "%02d", $0 % 60)) [daily-sales-report] step \($0) done" }
        + ["Traceback (most recent call last):", "RuntimeError: BigQuery credentials have expired"])
        .joined(separator: "\n")

    /**
     失敗時の標準エラーを詳細ペインのプレビューで見せるための見本。サンプルのログのパスは実在しないので、
     一時フォルダに書いたログを指す。作るたびに書き直すので、前のプレビューの内容は残らない
     */
    static var sampleFailureWithLogs: MonitoredItem {
        let out = previewLog(named: "daily-sales-report.log", text: "2026-10-29 09:00:00 [daily-sales-report] start")
        let err = previewLog(named: "daily-sales-report.err.log", text: sampleLogText)
        let job = LaunchdJob.sample(
            "com.example.daily-sales-report",
            schedule: Schedule(calendarEntries: (1...5).map { .init(minute: 0, hour: 9, weekday: $0) }),
            service: .init(state: "not running", pid: nil, runs: 58, lastExit: .code(1)),
            lastRun: .now.addingTimeInterval(-26 * 3600),
            standardOutPath: out.path(percentEncoded: false),
            standardErrorPath: err.path(percentEncoded: false),
            environmentVariables: [
                .init(name: "GOOGLE_APPLICATION_CREDENTIALS", value: "/Users/me/.config/gcloud/sales-report.json"),
                .init(name: "PATH", value: "/Users/me/.local/bin:/usr/bin:/bin"),
            ]
        )
        return MonitoredItem(key: job.label, name: job.label, status: .failed(reason: String(localized: "Exit code \(Int32(1))")), detail: .launchdJob(job))
    }

    /// サンプルのログのパスは実在しないので、一時フォルダに書いたログを指す。作るたびに書き直す
    private static func previewLog(named name: String, text: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "BreakerPreview", directoryHint: .isDirectory)
        let url = directory.appending(path: name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func launchdJob(
        _ label: String,
        status: ItemStatus,
        schedule: Schedule,
        service: LaunchdServiceInfo?,
        lastRun: Date?,
        isDisabledFile: Bool = false,
        isHomeJob: Bool = true,
        autoDescription: String? = nil
    ) -> MonitoredItem {
        let detail = LaunchdJob.sample(
            label,
            schedule: schedule,
            service: service,
            lastRun: lastRun,
            isDisabledFile: isDisabledFile,
            isHomeJob: isHomeJob
        )
        return MonitoredItem(key: label, name: label, status: status, detail: .launchdJob(detail), autoDescription: autoDescription)
    }
}

extension MonitoredItem.LaunchdJob {
    static func sample(
        _ label: String,
        schedule: Schedule,
        service: LaunchdServiceInfo? = nil,
        lastRun: Date? = nil,
        isDisabledFile: Bool = false,
        isHomeJob: Bool = true,
        origin: Origin = .userAgent,
        standardOutPath: String? = nil,
        standardErrorPath: String? = nil,
        environmentVariables: [EnvironmentVariable] = []
    ) -> Self {
        Self(
            label: label,
            origin: origin,
            plistURL: URL(filePath: "\(origin == .userAgent ? "/Users/me/" : "/")\(origin.relativePath)/\(label).plist\(isDisabledFile ? ".disabled" : "")"),
            isDisabledFile: isDisabledFile,
            isDisabledLabel: false,
            isHomeJob: isHomeJob,
            programArguments: isHomeJob
                ? ["/usr/bin/python3", "/Users/me/dev/scripts/\(label).py", "--quiet"]
                : ["/Users/me/Library/Application Support/Example/Updater.app/Contents/MacOS/Updater", "--check"],
            schedule: schedule,
            standardOutPath: standardOutPath ?? "/Users/me/Library/Logs/\(label).log",
            standardErrorPath: standardErrorPath ?? "/Users/me/Library/Logs/\(label).err.log",
            environmentVariables: environmentVariables,
            service: service,
            lastRun: lastRun
        )
    }
}

extension AppModel {
    /// 更新してもシステムを触らず、サンプルを返し直す。スケジュールの保存も plist を、メモの保存もアプリの設定を書き換えない
    static func preview(selectedID: MonitoredItem.ID? = nil, items samples: [MonitoredItem] = MonitoredItem.samples) -> AppModel {
        // 実際の一覧と同じ並び（種類 → 状態 → 名前）で見せる
        let items = ItemDiscovery.sorted(samples)
        let appModel = AppModel(
            items: items,
            performer: .preview,
            defaults: .preview,
            discover: { items }
        ) { _, _ in }
        appModel.selectedID = selectedID
        return appModel
    }

    /**
     `-BreakerSampleData YES` で起動したときの一覧（`AppEnvironment.usesSampleData`）。スクリーンショットで詳細のログの欄も埋まるよう、
     ログ付きの見本を同じ ID の項目と差し替え、代表的な失敗（#Preview "launchd (Failed with Logs)" と同じもの）を選んでおく
     */
    static func sampleData() -> AppModel {
        let failure = MonitoredItem.sampleFailureWithLogs
        let withLogs = [failure, MonitoredItem.sampleLogErrorWithLogs]
        let items = MonitoredItem.samples.map { item in
            withLogs.first { $0.id == item.id } ?? item
        }
        return preview(selectedID: failure.id, items: items)
    }
}

extension UserDefaults {
    /// 起動のたびに空から始めるので、前回のプレビューで書いたメモは残らない
    static var preview: UserDefaults {
        let suiteName = "Breaker.preview"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

extension ItemActionPerformer {
    /// プレビューのボタンを押しても launchctl や Finder を動かさない
    static let preview = ItemActionPerformer(
        jobActions: JobActions(launchctl: LaunchctlService(shell: PreviewShell())),
        workspace: PreviewWorkspace()
    )
}

private struct PreviewShell: ShellRunning {
    func run(_ executable: String, arguments: [String]) async throws -> ShellOutput {
        ShellOutput(status: 0, stdout: "", stderr: "")
    }
}

private struct PreviewWorkspace: WorkspaceOpening {
    func open(_ url: URL) -> Bool {
        true
    }

    func activateFileViewerSelecting(_ fileURLs: [URL]) {}

    func openAsText(_ url: URL) async throws {}

    func openApplication(at url: URL) async throws {}
}

/// プレビューのトグルで実際にログイン項目へ登録しない。押すと状態だけ切り替わる
@MainActor
final class PreviewLoginItem: LoginItemManaging {
    private(set) var status: LoginItemStatus

    init(status: LoginItemStatus) {
        self.status = status
    }

    func register() throws {
        status = .enabled
    }

    func unregister() throws {
        status = .disabled
    }

    func openSystemSettings() {}
}
