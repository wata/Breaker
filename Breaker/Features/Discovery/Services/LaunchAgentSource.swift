import Foundation

/**
 `~/Library/LaunchAgents` のジョブをすべて出す。アプリが入れたもの（Google の更新など）も消さずに
 ホームのジョブ（`isHomeJob`）と区別し、通知やバッジには数えない。
 `/Library/LaunchAgents` と `/Library/LaunchDaemons` のジョブも、状態を読むだけのジョブとして出す
 （操作や書き換えには管理者権限が要るため）
 */
struct LaunchAgentSource: ItemSource {
    typealias Origin = MonitoredItem.LaunchdJob.Origin

    let kind = MonitoredItem.Kind.launchdJob

    private static let disabledSuffix = ".disabled"

    private let launchctl: LaunchctlService
    private let homeDirectory: URL
    /// `/Library` を探す起点。テストで実機の `/Library` を読まないよう差し替えられるようにする
    private let rootDirectory: URL
    /// 走っていない検出のために、取り直しをまたいで runs を覚える。同じ Source を使い続けたときだけ実行を見られる
    private let runHistory: RunHistory
    /// 起動から間もない Mac でもテストの結果が変わらないよう、起動時刻は差し替えられるようにする
    private let bootTime: @Sendable () -> Date?

    init(
        launchctl: LaunchctlService = LaunchctlService(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        rootDirectory: URL = URL(filePath: "/", directoryHint: .isDirectory),
        runHistory: RunHistory = RunHistory(),
        bootTime: @escaping @Sendable () -> Date? = BootTime.current
    ) {
        self.launchctl = launchctl
        self.homeDirectory = homeDirectory
        self.rootDirectory = rootDirectory
        self.runHistory = runHistory
        self.bootTime = bootTime
    }

    func items() async throws -> [MonitoredItem] {
        let jobs = try Origin.allCases.flatMap { origin in
            try plistURLs(in: origin).compactMap { job(at: $0, origin: origin) }
        }
        guard !jobs.isEmpty else {
            return []
        }
        let disabledLabels = try await disabledLabels(of: Set(jobs.map { Self.domain(of: $0.origin) }))
        let now = Date.now
        let bootTime = bootTime()
        return await withTaskGroup(of: MonitoredItem.self) { group in
            for job in jobs {
                group.addTask {
                    await item(for: job, disabledLabels: disabledLabels[Self.domain(of: job.origin), default: []], now: now, bootTime: bootTime)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
    }

    /**
     一度もエージェントを入れていない Mac にはフォルダ自体が無い。ジョブが無いだけなので異常にしない。
     `.plist.disabled` は Breaker が `~/Library/LaunchAgents` で止めるときの印なので、そこでだけ拾う。
     閲覧のみの場所が読めなくても、ホームのジョブの一覧まで落とさないよう空にする
     */
    private func plistURLs(in origin: Origin) throws -> [URL] {
        let directory = directory(of: origin)
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return []
        }
        let read = {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        }
        let isUserAgent = origin == .userAgent
        let urls = isUserAgent ? try read() : (try? read()) ?? []
        return urls.filter { url in
            url.lastPathComponent.hasSuffix(".plist")
                || (isUserAgent && url.lastPathComponent.hasSuffix(".plist\(Self.disabledSuffix)"))
        }
    }

    private func directory(of origin: Origin) -> URL {
        let base = origin == .userAgent ? homeDirectory : rootDirectory
        return base.appending(path: origin.relativePath, directoryHint: .isDirectory)
    }

    /**
     gui ドメインの無効の一覧はホームのジョブの判定に要るので、読めなければ今までどおり全体を失敗にする。
     system ドメインの一覧は閲覧のみのデーモンにしか使わないので、読めなければ無効のものが無いとみなす
     */
    private func disabledLabels(of domains: Set<LaunchctlService.Domain>) async throws -> [LaunchctlService.Domain: Set<String>] {
        var labels = [LaunchctlService.Domain: Set<String>]()
        if domains.contains(.gui) {
            labels[.gui] = try await launchctl.disabledLabels()
        }
        if domains.contains(.system) {
            labels[.system] = (try? await launchctl.disabledLabels(in: .system)) ?? []
        }
        return labels
    }

    /// `/Library/LaunchAgents` のジョブはログイン中のユーザーの gui ドメインに読み込まれ、`/Library/LaunchDaemons` は system ドメインに入る
    private static func domain(of origin: Origin) -> LaunchctlService.Domain {
        switch origin {
        case .userAgent, .systemAgent:
            .gui

        case .daemon:
            .system
        }
    }

    /**
     読めない plist だけ nil。`Data(contentsOf:)` はシンボリックリンクをたどるので、リンク先の内容が読める。
     静的チェック（B）は `~/Library/LaunchAgents` だけ。`/Library` のジョブはパスが無くても利用者には直せない
     */
    private func job(at url: URL, origin: Origin) -> Job? {
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }
        let program = plist["Program"] as? String
        let programArguments = plist["ProgramArguments"] as? [String] ?? []
        let script = Self.userScript(program: program, programArguments: programArguments, home: homeDirectory)
        let standardOutPath = (plist["StandardOutPath"] as? String)?.expandingTilde(home: homeDirectory)
        let standardErrorPath = (plist["StandardErrorPath"] as? String)?.expandingTilde(home: homeDirectory)
        return Job(
            label: plist["Label"] as? String ?? url.lastPathComponent.replacing(/\.plist(\.disabled)?$/, with: ""),
            origin: origin,
            plistURL: url,
            isDisabledFile: url.lastPathComponent.hasSuffix(Self.disabledSuffix),
            isHomeJob: origin.isManageable && Self.isHomeJob(program: program, programArguments: programArguments, home: homeDirectory),
            programArguments: programArguments.isEmpty ? [program].compactMap { $0 } : programArguments,
            schedule: Schedule(plist: plist),
            standardOutPath: standardOutPath,
            standardErrorPath: standardErrorPath,
            // launchd は文字列以外の値を環境変数にしないので、表示からも外す
            environmentVariables: (plist["EnvironmentVariables"] as? [String: Any] ?? [:])
                .compactMapValues { $0 as? String }
                .map { MonitoredItem.LaunchdJob.EnvironmentVariable(name: $0.key, value: $0.value) }
                .sorted { $0.name < $1.name },
            requirements: origin.isManageable
                ? Self.requirements(
                    program: program,
                    programArguments: programArguments,
                    workingDirectory: plist["WorkingDirectory"] as? String,
                    logPaths: [standardOutPath, standardErrorPath].compactMap { $0 },
                    home: homeDirectory
                )
                : [],
            autoDescription: script.flatMap { ItemDescriptionReader.description(forScriptAt: URL(filePath: $0), home: homeDirectory) }
        )
    }

    /**
     1件の launchctl の失敗で全件を落とさないよう、その項目だけ警告にする。閲覧のみのジョブは、読めなくても
     利用者が直せることは無いので、異常にせず未確認にする。
     走っていない検出（A）とログのエラー（C）も `~/Library/LaunchAgents` だけ。`/Library` のジョブは見つけても利用者には直せない
     */
    private func item(for job: Job, disabledLabels: Set<String>, now: Date, bootTime: Date?) async -> MonitoredItem {
        // `~/Library/LaunchAgents` の ID はメモ（UserDefaults の itemNotes）のキーなので変えない。`/Library` のジョブは同じラベルが ~ にもあることがあるので場所を前置する
        let key = job.origin == .userAgent ? job.label : "/\(job.origin.relativePath)/\(job.label)"
        let isChecked = job.origin.isManageable
        let isDisabledLabel = disabledLabels.contains(job.label)
        let logModificationDate = LogReader.lastModificationDate(of: [job.standardOutPath, job.standardErrorPath].compactMap { $0 })
        var lastRun = logModificationDate
        let service: LaunchdServiceInfo?
        let status: ItemStatus
        do {
            service = try await launchctl.print(label: job.label, in: Self.domain(of: job.origin))
            let record = await runHistory.observe(key: key, runs: service?.runs, now: now)
            lastRun = [logModificationDate, record?.lastObservedRun].compactMap { $0 }.max()
            // ログを読むのは C の対象（直前の終了コードが 0）のときだけにして、ジョブの数だけ読まない
            let logError = isChecked && service?.lastExit == .code(0) ? await Self.logError(of: job, writtenSince: record?.lastRunNotBefore) : nil
            status = Self.status(
                isDisabledFile: job.isDisabledFile,
                isDisabledLabel: isDisabledLabel,
                service: service,
                keepAlive: job.schedule.keepAlive,
                fileFailure: HealthCheck.fileFailure(in: job.requirements, home: homeDirectory) { HealthCheck.fileState(atPath: $0) },
                missedRun: (isChecked ? record : nil).flatMap { record in
                    HealthCheck.missedRun(
                        schedule: job.schedule,
                        lastRun: lastRun,
                        watchStart: record.watchStart,
                        now: now,
                        bootTime: bootTime
                    )
                },
                logError: logError
            )
        } catch {
            service = nil
            status = isChecked ? .warning(reason: error.localizedDescription) : .unknown(reason: String(localized: "Can't read status"), note: error.localizedDescription)
        }
        let detail = MonitoredItem.LaunchdJob(
            label: job.label,
            origin: job.origin,
            plistURL: job.plistURL,
            isDisabledFile: job.isDisabledFile,
            isDisabledLabel: isDisabledLabel,
            isHomeJob: job.isHomeJob,
            programArguments: job.programArguments,
            schedule: job.schedule,
            standardOutPath: job.standardOutPath,
            standardErrorPath: job.standardErrorPath,
            environmentVariables: job.environmentVariables,
            service: service,
            lastRun: lastRun
        )
        return MonitoredItem(
            key: key,
            name: job.label,
            status: status,
            detail: .launchdJob(detail),
            autoDescription: job.autoDescription
        )
    }

    /// 標準エラーを先に見る。原因は標準エラーに出ることが多い。最後の実行より前に書かれたログは、直した後の古い失敗なので見ない
    private static func logError(of job: Job, writtenSince lastRunNotBefore: Date?) async -> String? {
        // 標準出力と標準エラーを同じファイルに出すジョブは1回だけ読む
        let paths = [job.standardErrorPath, job.standardOutPath].compactMap { $0 }.uniqued()
            .filter { path in
                guard let lastRunNotBefore else {
                    return true
                }
                return LogReader.lastModificationDate(of: [path]).map { $0 >= lastRunNotBefore } ?? false
            }
        return HealthCheck.logError(in: await LogReader.tails(of: paths, lineCount: HealthCheck.logLineCount))
    }
}

extension LaunchAgentSource {
    /// plist から読んだ、launchctl に問い合わせる前の情報
    private struct Job: Sendable {
        let label: String
        let origin: Origin
        let plistURL: URL
        let isDisabledFile: Bool
        let isHomeJob: Bool
        let programArguments: [String]
        let schedule: Schedule
        let standardOutPath: String?
        let standardErrorPath: String?
        let environmentVariables: [MonitoredItem.LaunchdJob.EnvironmentVariable]
        let requirements: [HealthCheck.Requirement]
        let autoDescription: String?
    }

    /**
     実際に起動するもの（Program、なければ ProgramArguments の先頭）がアプリでなく、
     かつ Program / ProgramArguments のどれかがホームのパスを含む（`zsh -c` の文字列の中も）ならホームのジョブ
     */
    static func isHomeJob(program: String?, programArguments: [String], home: URL) -> Bool {
        guard let executable = program ?? programArguments.first else {
            return false
        }
        return !isAppPath(executable.expandingTilde(home: home))
            && userScript(program: program, programArguments: programArguments, home: home) != nil
    }

    /// 用途の説明を読むスクリプト。`/bin/bash ~/x.sh` ではインタプリタではなく、ホームにある2つ目が本体
    static func userScript(program: String?, programArguments: [String], home: URL) -> String? {
        let homePath = home.path(percentEncoded: false).trimmingSuffix("/")
        return ([program].compactMap { $0 } + programArguments)
            .map { $0.expandingTilde(home: home) }
            .first { containsPath(homePath, in: $0) && !isAppPath($0) }
    }

    /**
     `zsh -c "cd /Users/me/x && …"` のように文字列の途中にあるパスも拾う。
     `/Users/me` が `/Users/meow/x.sh` に一致しないよう、直後が `/` か文字列の終わりのものだけを数える
     */
    private static func containsPath(_ path: String, in string: String) -> Bool {
        var searchRange = string.startIndex..<string.endIndex
        while let range = string.range(of: path, range: searchRange) {
            if range.upperBound == string.endIndex || string[range.upperBound] == "/" {
                return true
            }
            searchRange = range.upperBound..<string.endIndex
        }
        return false
    }

    /// アプリ本体か、自動更新が置かれる `~/Library/Application Support` の中。利用者が書いたスクリプトではない
    static func isAppPath(_ path: String) -> Bool {
        path.hasPrefix("/Applications/")
            || path.contains(".app/")
            || path.contains("/Library/Application Support/")
    }

    /**
     静的チェックで確かめるパス。起動するもの → スクリプト → 作業フォルダ → ログのフォルダの順（直す順）に並べる。
     起動するものは PATH を引かないので、絶対パスか `~/` のものだけ。`zsh -c "cd ~/x && …"` の文字列はパスではないので見ない
     */
    static func requirements(
        program: String?,
        programArguments: [String],
        workingDirectory: String?,
        logPaths: [String],
        home: URL
    ) -> [HealthCheck.Requirement] {
        let executable = (program ?? programArguments.first)?.expandingTilde(home: home)
        let arguments = programArguments.map { $0.expandingTilde(home: home) }
        let script = userScript(program: program, programArguments: programArguments, home: home).flatMap { script in
            let isCommandString = arguments.firstIndex(of: script).map { $0 > 0 && arguments[$0 - 1].wholeMatch(of: /-\w*c/) != nil } ?? false
            return script == executable || isCommandString ? nil : script
        }
        let logDirectories = logPaths.map { ($0 as NSString).deletingLastPathComponent }.uniqued()
        let requirements = [
            executable.map { HealthCheck.Requirement(kind: .executable, path: $0) },
            script.map { HealthCheck.Requirement(kind: .script, path: $0) },
            workingDirectory.map { HealthCheck.Requirement(kind: .workingDirectory, path: $0.expandingTilde(home: home)) },
        ].compactMap { $0 } + logDirectories.map { HealthCheck.Requirement(kind: .logDirectory, path: $0) }
        return requirements.filter { $0.path.hasPrefix("/") }
    }

    /**
     判定の順序に意味がある。意図して止めたものは異常にしない。未ロードのジョブは予定が来ても走らないので失敗。
     動いているものは直前の終了コードを見ない（KeepAlive ジョブは SIGTERM で再起動されると直前の終了がシグナルになるため）。
     静的チェックの問題は、終了コードより原因が分かるので理由を差し替える（まだ走っていなくても、次に走るときに失敗するので失敗）。
     ログのエラーは直前の終了コードが 0 のときだけ見る。終了コードが 0 でもジョブの仕事は失敗しているので失敗
     */
    static func status(
        isDisabledFile: Bool,
        isDisabledLabel: Bool,
        service: LaunchdServiceInfo?,
        keepAlive: Bool,
        fileFailure: ItemStatus? = nil,
        missedRun: Date? = nil,
        logError: String? = nil
    ) -> ItemStatus {
        // 止め方は補足に分ける。詳細の見出しは「無効」だけにし、止め方は `MonitoredItem.statusNote` が言い直す
        if isDisabledFile {
            return .inactive(reason: disabledReason, note: ".plist.disabled")
        }
        if isDisabledLabel {
            return .inactive(reason: disabledReason, note: "launchctl disable")
        }
        guard let service else {
            return .failed(reason: String(localized: "Not loaded"))
        }
        if service.isRunning {
            return .running
        }
        if let fileFailure {
            return fileFailure
        }
        if let failure = failure(of: service, keepAlive: keepAlive) {
            return .failed(reason: failure)
        }
        if let missedRun {
            return HealthCheck.missedRunStatus(missedRun)
        }
        if
            let logError,
            service.lastExit == .code(0)
        {
            return HealthCheck.logErrorStatus(logError)
        }
        return .ok
    }

    /// フォルダアクションの無効と同じ語
    static var disabledReason: String {
        String(localized: "Disabled", comment: "Status of a launchd job or folder action that is turned off")
    }

    private static func failure(of service: LaunchdServiceInfo, keepAlive: Bool) -> String? {
        if keepAlive {
            return String(localized: "KeepAlive job isn't running")
        }
        switch service.lastExit {
        case .code(let code) where code != 0:
            return String(localized: "Exit code \(code)")

        case .signal(let signal):
            return String(localized: "Terminated by signal \(signal)")

        case .never, .code:
            return nil
        }
    }
}
