import Foundation
import Synchronization
import Testing
@testable import Breaker

struct LaunchAgentSourceTests {
    /// 読めない plist 以外はすべて出し、アプリが入れたジョブはホームのジョブと区別する
    @Test func discoversAllJobsAndClassifiesThem() async throws {
        let home = try TemporaryDirectory()
        let agents = home.url.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        let repository = home.url.appending(path: "dev/repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let path = home.url.path(percentEncoded: false)
        let logURL = home.url.appending(path: "check.log")
        try Data().write(to: logURL)

        try writePlist([
            "Label": "com.example.check",
            "ProgramArguments": ["\(path)Library/Scripts/check.sh"],
            "StartCalendarInterval": ["Hour": 9, "Minute": 0],
            "StandardOutPath": logURL.path(percentEncoded: false),
            "StandardErrorPath": "~/missing.log",
        ], to: agents.appending(path: "com.example.check.plist"))
        // リポジトリ内の plist を LaunchAgents からリンクしている
        let linkTarget = repository.appending(path: "com.example.linked.plist")
        try writePlist(["Label": "com.example.linked", "Program": "\(path)dev/repo/run.sh", "KeepAlive": true], to: linkTarget)
        try FileManager.default.createSymbolicLink(at: agents.appending(path: "com.example.linked.plist"), withDestinationURL: linkTarget)
        try writePlist(["ProgramArguments": ["/bin/bash", "~/dev/repo/fetch.sh"]], to: agents.appending(path: "com.example.renamed.plist.disabled"))
        try writePlist(["Label": "com.example.tool", "ProgramArguments": ["\(path)bin/tool"]], to: agents.appending(path: "com.example.tool.plist"))
        // アプリが入れたもの。Program / ProgramArguments のないジョブも出す
        try writePlist(
            ["Label": "com.alfredapp.1password", "ProgramArguments": ["/usr/bin/osascript", "-e", "tell application id \"com.runningwithcrayons.Alfred\""]],
            to: agents.appending(path: "com.alfredapp.1password.plist")
        )
        try writePlist(["Label": "com.google.keystone.agent", "MachServices": ["com.google.keystone": true]], to: agents.appending(path: "com.google.keystone.agent.plist"))
        try writePlist(["Label": "com.example.prefix", "Program": "\(path)devtools/run.sh"], to: agents.appending(path: "com.example.prefix.plist"))
        try Data("not a plist".utf8).write(to: agents.appending(path: "broken.plist"))

        let running = try fixture("launchctl-print-running")
        let failed = try fixture("launchctl-print-failed")
        let shell = StubShell { call in
            switch call.arguments {
            case ["print-disabled", "gui/501"]:
                ShellOutput(status: 0, stdout: "disabled services = {\n\t\"com.example.tool\" => disabled\n}\n", stderr: "")

            case ["print", "gui/501/com.example.check"]:
                ShellOutput(status: 0, stdout: failed, stderr: "")

            case ["print", "gui/501/com.example.linked"]:
                ShellOutput(status: 0, stdout: running, stderr: "")

            default:
                ShellOutput(status: 113, stdout: "", stderr: "Could not find service")
            }
        }
        let source = self.source(shell, home: home.url)
        let items = try await source.items().reduce(into: [String: MonitoredItem]()) { $0[$1.name] = $1 }

        #expect(Set(items.keys) == [
            "com.example.check",
            "com.example.linked",
            "com.example.renamed",
            "com.example.tool",
            "com.alfredapp.1password",
            "com.google.keystone.agent",
            "com.example.prefix",
        ])
        let userJobs = Set(items.values.compactMap(job).filter(\.isHomeJob).map(\.label))
        #expect(userJobs == ["com.example.check", "com.example.linked", "com.example.renamed", "com.example.tool", "com.example.prefix"])
        #expect(job(items["com.google.keystone.agent"])?.programArguments == [])

        let check = try #require(job(items["com.example.check"]))
        // 起動するスクリプトが無いので、終了コードより原因の分かる理由を出す。launchd が失敗を報告しているので失敗のまま
        #expect(items["com.example.check"]?.status == .failed(reason: "Executable not found", note: "~/Library/Scripts/check.sh"))
        #expect(check.schedule.calendarEntries == [Schedule.CalendarEntry(minute: 0, hour: 9)])
        #expect(check.standardErrorPath == "\(path)missing.log")
        #expect(check.lastRun != nil)

        // 書き換えはリンク先に行うので、項目にはリンク自体の URL を持たせる
        let linked = try #require(job(items["com.example.linked"]))
        #expect(linked.plistURL.lastPathComponent == "com.example.linked.plist")
        #expect(linked.plistURL.deletingLastPathComponent().lastPathComponent == "LaunchAgents")
        #expect(linked.programArguments == ["\(path)dev/repo/run.sh"])
        #expect(linked.service?.pid == 87964)
        #expect(items["com.example.linked"]?.status == .running)

        let renamed = try #require(job(items["com.example.renamed"]))
        #expect(renamed.isDisabledFile)
        #expect(renamed.lastRun == nil)
        #expect(items["com.example.renamed"]?.status == .inactive(reason: "Disabled", note: ".plist.disabled"))

        #expect(items["com.example.tool"]?.status == .inactive(reason: "Disabled", note: "launchctl disable"))
    }

    /// エージェントを一度も入れていない Mac には LaunchAgents が無い。launchctl にも問い合わせない
    @Test func listsNothingWhenLaunchAgentsIsMissing() async throws {
        let home = try TemporaryDirectory()
        let shell = StubShell(output: ShellOutput(status: 0, stdout: "", stderr: ""))
        let source = self.source(shell, home: home.url)
        #expect(try await source.items().isEmpty)
        #expect(shell.calls.isEmpty)
    }

    @Test func printFailureMarksOnlyThatJob() async throws {
        let home = try TemporaryDirectory()
        let agents = home.url.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try writePlist(["Label": "com.example.a", "Program": "~/bin/a"], to: agents.appending(path: "com.example.a.plist"))
        try writePlist(["Label": "com.example.b", "Program": "~/bin/b"], to: agents.appending(path: "com.example.b.plist"))
        let bin = home.url.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: bin.appending(path: "b"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "b").path(percentEncoded: false))
        let exited = try fixture("launchctl-print-exited")
        let shell = StubShell { call in
            switch call.arguments.last {
            case "gui/501/com.example.a":
                ShellOutput(status: 5, stdout: "", stderr: "Input/output error")

            case "gui/501":
                ShellOutput(status: 0, stdout: "", stderr: "")

            default:
                ShellOutput(status: 0, stdout: exited, stderr: "")
            }
        }
        let items = try await source(shell, home: home.url).items()
        let statuses = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.status) })
        #expect(statuses["com.example.a"]?.isAbnormal == true)
        #expect(statuses["com.example.b"] == .ok)
    }

    /// 用途の説明は、ホームにあってアプリでない最初の引数（インタプリタの次のスクリプト）から読む
    @Test func readsDescriptionFromHomeScript() async throws {
        let home = try TemporaryDirectory()
        let agents = home.url.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        let scripts = home.url.appending(path: "scripts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("#!/bin/bash\n# バックアップを取る。\necho\n".utf8).write(to: scripts.appending(path: "backup.sh"))
        try writePlist(
            ["Label": "com.example.backup", "ProgramArguments": ["/bin/bash", "~/scripts/backup.sh"]],
            to: agents.appending(path: "com.example.backup.plist")
        )
        try writePlist(
            ["Label": "com.example.updater", "Program": "/Applications/Example.app/Contents/MacOS/Updater"],
            to: agents.appending(path: "com.example.updater.plist")
        )
        let shell = StubShell { call in
            call.arguments.first == "print-disabled"
                ? ShellOutput(status: 0, stdout: "", stderr: "")
                : ShellOutput(status: 113, stdout: "", stderr: "Could not find service")
        }
        let items = try await source(shell, home: home.url).items()
        let descriptions = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.autoDescription) })
        #expect(descriptions["com.example.backup"] == "バックアップを取る。")
        #expect(descriptions["com.example.updater"] == .some(nil))
    }

    @Test(arguments: [
        // インタプリタでホームのスクリプトを動かす（instagent）
        (nil, ["/bin/bash", "/Users/me/instagent-launcher.sh"], true),
        // `zsh -c` の文字列の中にホームのパスがある（vimeo）
        (nil, ["/bin/zsh", "-l", "-c", "cd \"/Users/me/ClaudeCoding/vimeo\" && python3 refresh.py"], true),
        ("~/bin/tool", [], true),
        (nil, ["/usr/bin/python3", "~/dev/repo/run.py"], true),
        // /Applications のアプリ（Mailspring）
        (nil, ["/Applications/Mailspring.app/Contents/MacOS/Mailspring"], false),
        // ~/Library/Application Support に入る自動更新（GoogleUpdater）
        ("/Users/me/Library/Application Support/Google/GoogleUpdater.app/Contents/MacOS/GoogleUpdater", [], false),
        // 起動するものがアプリなら、引数にホームのパスがあってもホームのジョブではない
        (nil, ["/Applications/Example.app/Contents/MacOS/Example", "/Users/me/Documents/file.txt"], false),
        // 名前がホームで始まるだけの別のフォルダはホームではない
        (nil, ["/bin/bash", "/Users/meow/x.sh"], false),
        (nil, ["/bin/zsh", "-c", "cd /Users/meow/x && ./run.sh"], false),
        (nil, ["/bin/zsh", "-c", "cp /Users/meow/a /Users/me/b"], true),
        // ホームのパスを含まない
        (nil, ["/usr/bin/osascript", "-e", "tell application id \"com.example.app\""], false),
        // Program も ProgramArguments もない（MachServices だけなど）
        (nil, [], false),
    ] as [(String?, [String], Bool)])
    func isHomeJob(program: String?, programArguments: [String], expected: Bool) {
        let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        #expect(LaunchAgentSource.isHomeJob(program: program, programArguments: programArguments, home: home) == expected)
    }

    @Test(arguments: [
        ("/Applications/Mailspring.app/Contents/MacOS/Mailspring", true),
        ("/Users/me/Library/Application Support/Google/GoogleUpdater/Current/GoogleUpdater.app/Contents/MacOS/GoogleUpdater", true),
        ("/Users/me/Library/Application Support/Example/agent", true),
        ("/bin/bash", false),
        ("/Users/me/instagent-launcher.sh", false),
    ])
    func isAppPath(path: String, expected: Bool) {
        #expect(LaunchAgentSource.isAppPath(path) == expected)
    }

    @Test func userScriptSkipsInterpreterAndAppPaths() {
        let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        let script = LaunchAgentSource.userScript(
            program: nil,
            programArguments: ["/usr/bin/python3", "/Users/me/Library/Application Support/Example/x.py", "~/scripts/run.py"],
            home: home
        )
        #expect(script == "/Users/me/scripts/run.py")
        #expect(LaunchAgentSource.userScript(program: nil, programArguments: ["/bin/bash", "-c", "echo"], home: home) == nil)
    }

    @Test(arguments: [
        // 意図して止めているものは、未ロードでも終了コードが失敗でも異常にしない
        (true, false, nil, false, ItemStatus.inactive(reason: "Disabled", note: ".plist.disabled")),
        (false, true, Info.exited(.code(1)), false, .inactive(reason: "Disabled", note: "launchctl disable")),
        // 未ロードのジョブは予定が来ても走らないので失敗
        (false, false, nil, false, .failed(reason: "Not loaded")),
        // KeepAlive ジョブが SIGTERM で再起動された直後は、動いていれば直前のシグナル終了を見ない
        (false, false, Info.running(lastExit: .signal(15)), true, .running),
        (false, false, Info.running(lastExit: .code(1)), false, .running),
        (false, false, Info.exited(.never), true, .failed(reason: "KeepAlive job isn't running")),
        (false, false, Info.exited(.code(1)), false, .failed(reason: "Exit code 1")),
        (false, false, Info.exited(.signal(9)), false, .failed(reason: "Terminated by signal 9")),
        (false, false, Info.exited(.code(0)), false, .ok),
        (false, false, Info.exited(.never), false, .ok),
    ] as [(Bool, Bool, LaunchdServiceInfo?, Bool, ItemStatus)])
    func status(isDisabledFile: Bool, isDisabledLabel: Bool, service: LaunchdServiceInfo?, keepAlive: Bool, expected: ItemStatus) {
        let status = LaunchAgentSource.status(isDisabledFile: isDisabledFile, isDisabledLabel: isDisabledLabel, service: service, keepAlive: keepAlive)
        #expect(status == expected)
    }

    /**
     無効 → 未ロード → 実行中 → 静的チェック → Exit code → 走っていない → ログのエラー の順。
     静的チェックは原因の分かる理由に差し替え、まだ走っていなくても失敗。ログのエラーも終了コード 0 のまま失敗
     */
    @Test func statusPriorityWithChecks() {
        let problem = ItemStatus.failed(reason: "Script not found", note: "~/dev/run.py")
        let missed = Date(timeIntervalSince1970: 1_800_000_000)
        let missedStatus = HealthCheck.missedRunStatus(missed)
        func status(_ service: LaunchdServiceInfo?, keepAlive: Bool = false, fileFailure: ItemStatus? = nil, missedRun: Date? = nil, logError: String? = nil, isDisabledFile: Bool = false) -> ItemStatus {
            LaunchAgentSource.status(
                isDisabledFile: isDisabledFile,
                isDisabledLabel: false,
                service: service,
                keepAlive: keepAlive,
                fileFailure: fileFailure,
                missedRun: missedRun,
                logError: logError
            )
        }

        #expect(status(Info.exited(.code(1)), fileFailure: problem, isDisabledFile: true) == .inactive(reason: "Disabled", note: ".plist.disabled"))
        #expect(status(nil, fileFailure: problem, missedRun: missed) == .failed(reason: "Not loaded"))
        #expect(status(Info.running(lastExit: .code(1)), fileFailure: problem, missedRun: missed, logError: "Error") == .running)

        #expect(status(Info.exited(.code(1)), fileFailure: problem) == problem)
        #expect(status(Info.exited(.signal(9)), fileFailure: problem) == problem)
        #expect(status(Info.exited(.never), keepAlive: true, fileFailure: problem) == problem)
        #expect(status(Info.exited(.never), fileFailure: problem, missedRun: missed) == problem)
        #expect(status(Info.exited(.code(0)), fileFailure: problem, logError: "Error") == problem)
        #expect(status(Info.exited(.never), fileFailure: problem) == problem)

        #expect(status(Info.exited(.code(1)), missedRun: missed, logError: "Error") == .failed(reason: "Exit code 1"))
        #expect(status(Info.exited(.code(0)), missedRun: missed, logError: "Error") == missedStatus)
        #expect(status(Info.exited(.never), missedRun: missed) == missedStatus)
        #expect(missedStatus == .failed(reason: "Didn't run as scheduled", note: MonitoredItem.format(missed)))

        #expect(status(Info.exited(.code(0)), logError: "Error: token expired") == .failed(reason: "Error in log", note: "Error: token expired"))
        // 直前の終了コードが 0 でなければログのエラーは見ない（まだ走っていないときも前回のログなので見ない）
        #expect(status(Info.exited(.never), logError: "Error") == .ok)
        #expect(status(Info.exited(.code(0))) == .ok)
    }

    /// Exit code 0 のジョブだけ、標準エラーの末尾からエラー行を拾う
    @Test func itemsWarnOnLogErrorAfterSuccess() async throws {
        let home = try TemporaryDirectory()
        let agents = home.url.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let log = home.url.appending(path: "a.log")
        try Data("start\nRuntimeError: token expired\ndone\n".utf8).write(to: log)
        for label in ["com.example.a", "com.example.b"] {
            try writePlist(
                ["Label": label, "ProgramArguments": ["/bin/sh", "-c", "true"], "StandardErrorPath": log.path(percentEncoded: false)],
                to: agents.appending(path: "\(label).plist")
            )
        }
        let exited = try fixture("launchctl-print-exited")
        let failed = try fixture("launchctl-print-failed")
        let shell = StubShell { call in
            switch call.arguments.last {
            case "gui/501":
                ShellOutput(status: 0, stdout: "", stderr: "")

            case "gui/501/com.example.a":
                ShellOutput(status: 0, stdout: exited, stderr: "")

            default:
                ShellOutput(status: 0, stdout: failed, stderr: "")
            }
        }
        let items = try await source(shell, home: home.url).items()
        let statuses = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.status) })
        #expect(statuses["com.example.a"] == .failed(reason: "Error in log", note: "RuntimeError: token expired"))
        #expect(statuses["com.example.b"] == .failed(reason: "Exit code 1"))
    }

    /**
     ログに何も書かないジョブ。見張りを始めてから runs が変わらずログも古ければ走っていない、
     runs が増えていれば（ログが古くても）走っている
     */
    @Test func itemsUseObservedRunsForMissedRuns() async throws {
        let home = try TemporaryDirectory()
        let agents = home.url.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let log = home.url.appending(path: "quiet.log")
        try Data().write(to: log)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-30 * 86400)], ofItemAtPath: log.path(percentEncoded: false))
        try writePlist(
            ["Label": "com.example.quiet", "ProgramArguments": ["/bin/sh", "-c", "true"], "StartInterval": 60, "StandardOutPath": log.path(percentEncoded: false)],
            to: agents.appending(path: "com.example.quiet.plist")
        )
        let exited = try fixture("launchctl-print-exited")
        let runs = Mutex(1)
        let shell = StubShell { call in
            guard call.arguments.last != "gui/501" else {
                return ShellOutput(status: 0, stdout: "", stderr: "")
            }
            return ShellOutput(status: 0, stdout: exited.replacing("runs = 1", with: "runs = \(runs.withLock { $0 })"), stderr: "")
        }
        let history = RunHistory()
        let watchStart = Date.now.addingTimeInterval(-2 * 3600)
        _ = await history.observe(key: "com.example.quiet", runs: 1, now: watchStart)
        // 起動から間もない Mac でも結果が変わらないよう、起動は見張り開始より前に固定する
        let bootTime = Date.now.addingTimeInterval(-7 * 86400)
        let source = LaunchAgentSource(
            launchctl: LaunchctlService(shell: shell, uid: 501),
            homeDirectory: home.url,
            rootDirectory: Self.root(in: home.url),
            runHistory: history,
            bootTime: { bootTime }
        )

        let missed = try #require(try await source.items().first)
        #expect(missed.status.reason == "Didn't run as scheduled")
        #expect(missed.status.note != nil)

        runs.withLock { $0 = 2 }
        let observed = try #require(try await source.items().first)
        #expect(observed.status == .ok)
        #expect(try #require(job(observed)?.lastRun) > watchStart)
    }

    /// 実機の launchd ジョブの判定を目で確かめる用。`TEST_RUNNER_BREAKER_LIVE_LAUNCHD=1 xcodebuild test ...` のときだけ動き、launchctl は読むだけ
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BREAKER_LIVE_LAUNCHD"] != nil))
    func printsLiveJobs() async throws {
        let items = try await LaunchAgentSource().items().sorted { $0.id < $1.id }
        let lines = items.map { "\($0.id) — \($0.status) — isHomeJob=\(job($0)?.isHomeJob == true) reported=\($0.isReportedAbnormal)" }
        print("BREAKER_LIVE_LAUNCHD \(items.count) items\n" + lines.joined(separator: "\n"))
    }

    /// テストで実機の `/Library` を読まないよう、`/Library` の代わりは一時フォルダの中に置く（作らなければ無いものとして扱われる）
    private static func root(in home: URL) -> URL {
        home.appending(path: "root", directoryHint: .isDirectory)
    }

    private func source(_ shell: StubShell, home: URL, runHistory: RunHistory = RunHistory()) -> LaunchAgentSource {
        LaunchAgentSource(
            launchctl: LaunchctlService(shell: shell, uid: 501),
            homeDirectory: home,
            rootDirectory: Self.root(in: home),
            runHistory: runHistory,
            bootTime: { Date.now.addingTimeInterval(-7 * 86400) }
        )
    }

    /**
     `/Library/LaunchAgents` は gui ドメイン、`/Library/LaunchDaemons` は system ドメインで状態を読み、ホームのジョブにはしない。
     同じラベルが `~/Library/LaunchAgents` にもあっても ID はぶつからず、`~` 側の ID はラベルのまま変えない
     */
    @Test func discoversLibraryJobsAsReadOnly() async throws {
        let home = try TemporaryDirectory()
        let userAgents = home.url.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        let systemAgents = Self.root(in: home.url).appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        let systemDaemons = Self.root(in: home.url).appending(path: "Library/LaunchDaemons", directoryHint: .isDirectory)
        for directory in [userAgents, systemAgents, systemDaemons] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // 実機の Google の更新と同じく、中身の無い plist が両方にある
        try writePlist([:], to: userAgents.appending(path: "com.google.keystone.agent.plist"))
        try writePlist([:], to: systemAgents.appending(path: "com.google.keystone.agent.plist"))
        try writePlist(["Label": "com.example.agent", "Program": "/Applications/Example.app/Contents/MacOS/Agent"], to: systemAgents.appending(path: "com.example.agent.plist"))
        // `.plist.disabled` は `~/Library/LaunchAgents` でしか拾わない
        try writePlist(["Label": "com.example.renamed"], to: systemAgents.appending(path: "com.example.renamed.plist.disabled"))
        try writePlist(["Label": "com.example.daemon", "Program": "/Library/PrivilegedHelperTools/com.example.daemon"], to: systemDaemons.appending(path: "com.example.daemon.plist"))
        try writePlist(["Label": "com.example.off", "Program": "/Library/PrivilegedHelperTools/com.example.off"], to: systemDaemons.appending(path: "com.example.off.plist"))
        try writePlist(["Label": "com.example.secret", "Program": "/Library/PrivilegedHelperTools/com.example.secret"], to: systemDaemons.appending(path: "com.example.secret.plist"))

        let running = try fixture("launchctl-print-running")
        let failed = try fixture("launchctl-print-failed")
        let shell = StubShell { call in
            switch call.arguments {
            case ["print-disabled", "gui/501"]:
                ShellOutput(status: 0, stdout: "", stderr: "")

            case ["print-disabled", "system"]:
                ShellOutput(status: 0, stdout: "disabled services = {\n\t\"com.example.off\" => disabled\n}\n", stderr: "")

            case ["print", "gui/501/com.example.agent"]:
                ShellOutput(status: 0, stdout: running, stderr: "")

            case ["print", "system/com.example.daemon"]:
                ShellOutput(status: 0, stdout: failed, stderr: "")

            case ["print", "system/com.example.secret"]:
                ShellOutput(status: 1, stdout: "", stderr: "Operation not permitted")

            default:
                ShellOutput(status: 113, stdout: "", stderr: "Could not find service")
            }
        }
        let items = try await source(shell, home: home.url).items()
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        #expect(Set(byID.keys) == [
            "launchdJob:com.google.keystone.agent",
            "launchdJob:/Library/LaunchAgents/com.google.keystone.agent",
            "launchdJob:/Library/LaunchAgents/com.example.agent",
            "launchdJob:/Library/LaunchDaemons/com.example.daemon",
            "launchdJob:/Library/LaunchDaemons/com.example.off",
            "launchdJob:/Library/LaunchDaemons/com.example.secret",
        ])
        #expect(job(byID["launchdJob:com.google.keystone.agent"])?.origin == .userAgent)
        #expect(job(byID["launchdJob:/Library/LaunchAgents/com.google.keystone.agent"])?.origin == .systemAgent)
        #expect(job(byID["launchdJob:/Library/LaunchDaemons/com.example.daemon"])?.origin == .daemon)
        #expect(items.compactMap(job).allSatisfy { !$0.isHomeJob })

        #expect(byID["launchdJob:/Library/LaunchAgents/com.example.agent"]?.status == .running)
        #expect(byID["launchdJob:/Library/LaunchDaemons/com.example.daemon"]?.status == .failed(reason: "Exit code 1"))
        #expect(byID["launchdJob:/Library/LaunchDaemons/com.example.off"]?.status == .inactive(reason: "Disabled", note: "launchctl disable"))
        let secret = try #require(byID["launchdJob:/Library/LaunchDaemons/com.example.secret"])
        #expect(secret.status.title == "Unknown")
        #expect(secret.status.fullReason?.hasPrefix("Can't read status (") == true)
        #expect(!secret.status.isAbnormal)
        #expect(items.allSatisfy { !$0.isReportedAbnormal })

        // デーモンを gui ドメインで探さない
        #expect(!shell.calls.contains { $0.arguments.last?.hasPrefix("gui/501/com.example.daemon") == true })
    }

    /// 閲覧のみのジョブには、走っていない検出（A）・静的チェック（B）・ログのエラー（C）を当てない
    @Test func libraryJobsSkipHealthChecks() async throws {
        let home = try TemporaryDirectory()
        let systemAgents = Self.root(in: home.url).appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: systemAgents, withIntermediateDirectories: true)
        let log = home.url.appending(path: "quiet.log")
        try Data("RuntimeError: token expired\n".utf8).write(to: log)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-30 * 86400)], ofItemAtPath: log.path(percentEncoded: false))
        try writePlist(
            [
                "Label": "com.example.quiet",
                "ProgramArguments": ["/bin/bash", "~/missing.sh"],
                "WorkingDirectory": "/missing",
                "StartInterval": 60,
                "StandardErrorPath": log.path(percentEncoded: false),
            ],
            to: systemAgents.appending(path: "com.example.quiet.plist")
        )
        let exited = try fixture("launchctl-print-exited")
        let shell = StubShell { call in
            call.arguments.first == "print-disabled"
                ? ShellOutput(status: 0, stdout: "", stderr: "")
                : ShellOutput(status: 0, stdout: exited, stderr: "")
        }
        let history = RunHistory()
        _ = await history.observe(key: "/Library/LaunchAgents/com.example.quiet", runs: 1, now: Date.now.addingTimeInterval(-2 * 3600))

        let item = try #require(try await source(shell, home: home.url, runHistory: history).items().first)
        #expect(item.status == .ok)
        #expect(job(item)?.isHomeJob == false)
    }

    private func job(_ item: MonitoredItem?) -> MonitoredItem.LaunchdJob? {
        guard case .launchdJob(let job) = item?.detail else {
            return nil
        }
        return job
    }

    private func writePlist(_ plist: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }
}

private enum Info {
    static func running(lastExit: LaunchdServiceInfo.LastExit) -> LaunchdServiceInfo {
        LaunchdServiceInfo(state: "running", pid: 100, runs: 2, lastExit: lastExit)
    }

    static func exited(_ lastExit: LaunchdServiceInfo.LastExit) -> LaunchdServiceInfo {
        LaunchdServiceInfo(state: "not running", pid: nil, runs: 1, lastExit: lastExit)
    }
}
