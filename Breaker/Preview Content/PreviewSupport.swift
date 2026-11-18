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
            processStartDate: .now.addingTimeInterval(-2 * 86400 - 5 * 3600),
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
        sampleNetwork,
        sampleSystemLoad,
        sampleStorage,
    ]

    /// Wi-Fi で、どのチェックも正常なネットワーク。判定は実際の判定表に通して決める
    static let sampleNetwork: MonitoredItem = {
        let health = NetworkHealth(
            pathStatus: .satisfied,
            interface: .wifi,
            isExpensive: false,
            isConstrained: false,
            routerAddress: "192.168.1.1",
            dnsServers: ["192.168.1.1"],
            routerPing: .init(destination: "192.168.1.1", receivedCount: 10, lossRate: 0, averageMilliseconds: 3.4),
            internetPing: .init(destination: NetworkSource.internetPingDestination, receivedCount: 10, lossRate: 0, averageMilliseconds: 12.8),
            dnsLookup: .resolved(milliseconds: 18),
            internetAccess: .reachable,
            wifi: .init(
                interfaceName: "en0",
                ssid: "Example Wi-Fi",
                rssi: -52,
                noise: -94,
                channelNumber: 36,
                band: .fiveGigahertz,
                channelWidth: 80,
                phyMode: "802.11ax",
                transmitRate: 864
            ),
            lastSpeedTest: SpeedTestRecord.sample,
            isTestingSpeed: false
        )
        return MonitoredItem(key: "health", name: Kind.network.title, status: NetworkCheck.status(of: health), detail: .network(health))
    }()

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

    static let sampleSourceFailure = ItemDiscovery.sourceFailure(
        of: .folderAction,
        message: "Not authorized to send Apple events to System Events. (-1743)"
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
        processStartDate: Date? = nil,
        autoDescription: String? = nil
    ) -> MonitoredItem {
        let detail = LaunchdJob.sample(
            label,
            schedule: schedule,
            service: service,
            lastRun: lastRun,
            isDisabledFile: isDisabledFile,
            isHomeJob: isHomeJob,
            processStartDate: processStartDate
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
        environmentVariables: [EnvironmentVariable] = [],
        processStartDate: Date? = nil
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
            lastRun: lastRun,
            processStartDate: processStartDate
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

extension SpeedTestRecord {
    static let sample = SpeedTestRecord(
        date: .now.addingTimeInterval(-20 * 60),
        outcome: .succeeded(.init(
            downloadBitsPerSecond: 146_000_000,
            uploadBitsPerSecond: 132_000_000,
            responsiveness: 1027,
            baseRoundTripMilliseconds: 14
        ))
    )
}

extension SpeedTestScheduler {
    /// 見本データとプレビュー用。networkQuality を走らせず（約300MB 通信する）、前回の結果に見本の値を出す
    static func sampleData() -> SpeedTestScheduler {
        let defaults = UserDefaults.preview
        defaults.set(try? JSONEncoder().encode(SpeedTestRecord.sample), forKey: lastRecordKey)
        defaults.set(try? JSONEncoder().encode(SpeedTestRecord.sampleHistory), forKey: historyKey)
        return SpeedTestScheduler(
            speedTester: PreviewSpeedTester(),
            conditions: { .init(latestCheck: nil) },
            defaults: defaults
        )
    }
}

/// 押しても測らず、見本の値を今の時刻で返す
private struct PreviewSpeedTester: SpeedTesting {
    func measure() async throws -> SpeedTestRecord {
        SpeedTestRecord(date: .now, outcome: SpeedTestRecord.sample.outcome)
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
    func run(_ executable: String, arguments: [String], timeout: Duration?) async throws -> ShellOutput {
        ShellOutput(status: 0, stdout: "", stderr: "")
    }
}

private struct PreviewWorkspace: WorkspaceOpening {
    func open(_ url: URL) -> Bool {
        true
    }

    func activateFileViewerSelecting(_ fileURLs: [URL]) {}

    func openAsText(_ url: URL) async throws {}
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

/// プレビューのボタンで実際に位置情報の許可を求めない。押すと許可されたことにする
@MainActor
final class PreviewLocationAuthorization: LocationAuthorizing {
    private(set) var status: LocationAuthorizationStatus

    init(status: LocationAuthorizationStatus) {
        self.status = status
    }

    func requestAuthorization() async -> LocationAuthorizationStatus {
        status = .authorized
        return status
    }

    func openSystemSettings() {}
}

extension MonitoredItem {
    /// 外部へのロスと弱い電波がある Wi-Fi。ルーターは ping に応答しないが、インターネットには届いている
    static let sampleNetworkWarning: MonitoredItem = {
        let health = NetworkHealth(
            pathStatus: .satisfied,
            interface: .wifi,
            isExpensive: false,
            isConstrained: false,
            routerAddress: "192.168.1.1",
            dnsServers: ["192.168.1.1", "1.1.1.1"],
            routerPing: .init(destination: "192.168.1.1", receivedCount: 0, lossRate: 1, averageMilliseconds: nil),
            internetPing: .init(destination: NetworkSource.internetPingDestination, receivedCount: 8, lossRate: 0.2, averageMilliseconds: 48.6),
            dnsLookup: .resolved(milliseconds: 24),
            internetAccess: .reachable,
            wifi: .init(
                interfaceName: "en0",
                ssid: nil,
                rssi: -78,
                noise: -92,
                channelNumber: 6,
                band: .twoPointFourGigahertz,
                channelWidth: 20,
                phyMode: "802.11n",
                transmitRate: 72
            ),
            lastSpeedTest: SpeedTestRecord.sample,
            isTestingSpeed: false
        )
        return MonitoredItem(key: "health", name: Kind.network.title, status: NetworkCheck.status(of: health), detail: .network(health))
    }()

    /// どのインターフェイスも使えない。経路が無いので ping・DNS・到達確認・Wi-Fi は測っていない
    static let sampleNetworkOffline: MonitoredItem = {
        let health = NetworkHealth(
            pathStatus: .unsatisfied,
            interface: .none,
            isExpensive: false,
            isConstrained: false,
            routerAddress: nil,
            dnsServers: [],
            routerPing: nil,
            internetPing: nil,
            dnsLookup: nil,
            internetAccess: nil,
            wifi: nil,
            lastSpeedTest: SpeedTestRecord.sample,
            isTestingSpeed: false
        )
        return MonitoredItem(key: "health", name: Kind.network.title, status: NetworkCheck.status(of: health), detail: .network(health))
    }()
}

extension SpeedTestRecord {
    /**
     速度の推移のグラフの見本。直近7日を3時間ごとに測ったことにし、線の形が読み取れるよう上下する波を付ける。
     最後は `sample` と同じ値にして、大きな数字とグラフの右端をそろえる
     */
    static let sampleHistory: [SpeedTestRecord] = {
        let interval: TimeInterval = 3 * 60 * 60
        let count = 7 * 24 / 3
        let earlier = (1..<count).reversed().map { index in
            let wave = sin(Double(index) * .pi / 4)
            return SpeedTestRecord(
                date: sample.date.addingTimeInterval(-Double(index) * interval),
                outcome: .succeeded(.init(
                    downloadBitsPerSecond: (130 + 30 * wave) * 1_000_000,
                    uploadBitsPerSecond: (110 + 20 * wave) * 1_000_000,
                    responsiveness: 1000,
                    baseRoundTripMilliseconds: 14
                ))
            )
        }
        return earlier + [sample]
    }()
}


extension MonitoredItem {
    /**
     3時間前から1つのアプリが CPU を使い続けている負荷。記録は1分ごとに24時間分を作り、判定は実際の判定に通して決める。
     ビルドのような短い山も混ぜ、短い山では鳴らないことをグラフで見比べられるようにする
     */
    static let sampleSystemLoad: MonitoredItem = {
        let now = Date.now
        let coreCount = 10
        let history = (0..<(24 * 60)).reversed().map { minutesAgo in
            let isBuilding = (minutesAgo + 60) % 180 < 6
            let isStuck = minutesAgo < 3 * 60
            let consumers = [
                LoadSample.Consumer(name: "Example Reel", cpuPercent: isStuck ? 65 + Double(minutesAgo % 5) * 3 : 2),
                LoadSample.Consumer(name: "Xcode", cpuPercent: isBuilding ? 450 : 10),
                LoadSample.Consumer(name: "Safari", cpuPercent: 20 + Double(minutesAgo % 7) * 2),
                LoadSample.Consumer(name: "WindowServer", cpuPercent: 30),
            ]
            .sorted { $0.cpuPercent > $1.cpuPercent }
            return LoadSample(
                date: now.addingTimeInterval(-Double(minutesAgo) * 60),
                cpuPercent: consumers.reduce(20) { $0 + $1.cpuPercent },
                consumers: consumers
            )
        }
        let consumers = [
            SystemLoad.Consumer(name: "Example Reel", bundlePath: nil, cpuPercent: 68),
            SystemLoad.Consumer(name: "WindowServer", bundlePath: nil, cpuPercent: 30),
            SystemLoad.Consumer(name: "Safari", bundlePath: "/Applications/Safari.app", cpuPercent: 24),
            SystemLoad.Consumer(name: "Xcode", bundlePath: nil, cpuPercent: 10),
        ]
        let load = SystemLoad(
            cpuPercent: history.last?.cpuPercent ?? 0,
            coreCount: coreCount,
            loadAverage: 3.2,
            thermalState: .nominal,
            memoryPressure: .normal,
            consumers: consumers,
            history: history
        )
        return MonitoredItem(key: "load", name: Kind.systemLoad.title, status: LoadCheck.finding(in: load, now: now)?.status ?? .ok, detail: .systemLoad(load))
    }()

    /// 空きが 10% を切った起動ディスク。走査の結果は `StorageScanScheduler.sampleData()` と同じものを持たせる
    static let sampleStorage: MonitoredItem = {
        let usage = StorageUsage(capacityBytes: 994_000_000_000, availableBytes: 82_000_000_000, scan: StorageScan.sample)
        return MonitoredItem(key: "volume", name: Kind.storage.title, status: StorageSource.status(of: usage), detail: .storage(usage))
    }()
}

extension StorageScan {
    /// 前回から DerivedData とシミュレータが膨らんだ走査
    static let sample = StorageScan(
        date: .now.addingTimeInterval(-2 * 3600),
        previousDate: .now.addingTimeInterval(-8 * 3600),
        locations: [
            .init(location: .derivedData, path: "/Users/me/Library/Developer/Xcode/DerivedData", bytes: 148_000_000_000, previousBytes: 112_000_000_000),
            .init(location: .simulators, path: "/Users/me/Library/Developer/CoreSimulator", bytes: 64_000_000_000, previousBytes: 51_000_000_000),
            .init(location: .caches, path: "/Users/me/Library/Caches", bytes: 38_000_000_000, previousBytes: 37_600_000_000),
            .init(location: .applicationSupport, path: "/Users/me/Library/Application Support", bytes: 31_000_000_000, previousBytes: 30_900_000_000),
            .init(location: .nodeModules, path: "/Users/me", bytes: 22_000_000_000, previousBytes: 21_000_000_000),
            .init(location: .deviceSupport, path: "/Users/me/Library/Developer/Xcode", bytes: 18_000_000_000, previousBytes: 18_000_000_000),
            .init(location: .npm, path: "/Users/me/.npm", bytes: 9_000_000_000, previousBytes: 8_800_000_000),
        ]
    )
}

extension StorageScanScheduler {
    /// 見本データとプレビュー用。du を走らせず、前回の結果に見本の値を出す
    static func sampleData() -> StorageScanScheduler {
        let defaults = UserDefaults.preview
        defaults.set(try? JSONEncoder().encode(StorageScan.sample), forKey: lastScanKey)
        return StorageScanScheduler(diskUsage: PreviewDiskUsage(), defaults: defaults)
    }
}

/// 押しても走査せず、見本の値を今の時刻で返す
private struct PreviewDiskUsage: StorageScanning {
    func scan(previous: StorageScan?) async -> StorageScan {
        StorageScan(date: .now, previousDate: previous?.date, locations: StorageScan.sample.locations)
    }
}
