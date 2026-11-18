import Foundation
import Testing
@testable import Breaker

@MainActor
struct AIPromptTests {
    /// スクリプトがリポジトリの中にあれば、そのルートへ cd する。プロンプトにはジョブの定義とログの末尾を入れる
    @Test func launchdPromptStartsAtRepositoryRoot() async throws {
        let directory = try TemporaryDirectory()
        let home = directory.url
        let repository = home.appending(path: "dev/backup", directoryHint: .isDirectory)
        let script = repository.appending(path: "scripts/run.sh")
        try FileManager.default.createDirectory(at: repository.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: script)
        let log = home.appending(path: "backup.log")
        try (1...60).map { "line \($0)" }.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        let missingLog = home.appending(path: "missing/backup.err.log")
        let job = MonitoredItem.LaunchdJob(
            label: "com.example.backup",
            origin: .userAgent,
            plistURL: URL(filePath: "/Users/me/Library/LaunchAgents/com.example.backup.plist"),
            isDisabledFile: false,
            isDisabledLabel: false,
            isHomeJob: true,
            programArguments: ["/bin/zsh", "~/dev/backup/scripts/run.sh", "--dry run"],
            schedule: Schedule(interval: 1800),
            standardOutPath: log.path(percentEncoded: false),
            standardErrorPath: missingLog.path(percentEncoded: false),
            environmentVariables: [.init(name: "PATH", value: "/usr/bin:/bin")],
            service: nil,
            lastRun: nil,
            processStartDate: nil
        )
        let item = MonitoredItem(key: job.label, name: "backup", status: .failed(reason: "Exit code 1", note: "Last run failed"), detail: .launchdJob(job))

        let prompt = await AIPrompt.make(for: item, home: home, fileManager: .default)

        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "cd \(repository.path(percentEncoded: false).trimmingSuffix("/"))")
        #expect(prompt.contains("problem with the launchd job below"))
        #expect(lines.contains("Name: backup"))
        #expect(lines.contains("Status: Exit code 1"))
        #expect(lines.contains("Status detail: Last run failed"))
        #expect(lines.contains("Label: com.example.backup"))
        #expect(lines.contains("plist: /Users/me/Library/LaunchAgents/com.example.backup.plist"))
        #expect(lines.contains("ProgramArguments: /bin/zsh ~/dev/backup/scripts/run.sh '--dry run'"))
        #expect(lines.contains("Script: \(script.path(percentEncoded: false))"))
        #expect(lines.contains("Schedule: Every 30 minutes"))
        #expect(lines.contains("  PATH=/usr/bin:/bin"))
        #expect(lines.contains("Standard output log: \(log.path(percentEncoded: false)) (last 50 lines)"))
        // 末尾 50 行だけ
        #expect(!lines.contains("line 10"))
        #expect(lines.contains("line 11"))
        #expect(lines.contains("line 60"))
        #expect(lines.contains("Standard error log: \(missingLog.path(percentEncoded: false)) (not found)"))
    }

    @Test func scriptOutsideRepositoryUsesScriptFolder() throws {
        let directory = try TemporaryDirectory()
        let script = directory.url.appending(path: "bin/run.sh")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: script)
        let job = MonitoredItem.LaunchdJob.stub(programArguments: [script.path(percentEncoded: false)])
        let item = MonitoredItem(key: job.label, name: job.label, status: .failed(reason: "Exit code 1"), detail: .launchdJob(job))

        let folder = AIPrompt.workingDirectory(for: item, home: directory.url, fileManager: .default)

        #expect(folder?.path(percentEncoded: false) == script.deletingLastPathComponent().path(percentEncoded: false))
    }

    /// 動かすスクリプトがホームに無い（`/usr/bin` のコマンドだけなど）ジョブは、plist を直すことになるので plist のフォルダ
    @Test func launchdWithoutScriptUsesPlistFolder() throws {
        let directory = try TemporaryDirectory()
        let job = MonitoredItem.LaunchdJob.stub(programArguments: ["/usr/bin/true"])
        let item = MonitoredItem(key: job.label, name: job.label, status: .failed(reason: "Exit code 1"), detail: .launchdJob(job))

        let folder = AIPrompt.workingDirectory(for: item, home: directory.url, fileManager: .default)

        #expect(folder?.path(percentEncoded: false) == "/tmp/LaunchAgents/")
    }

    @Test func cronPromptIncludesCrontabLine() async throws {
        let directory = try TemporaryDirectory()
        let repository = directory.url.appending(path: "repo", directoryHint: .isDirectory)
        let script = repository.appending(path: "sync.sh")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        // worktree の `.git` はフォルダではなくファイル
        try Data("gitdir: /elsewhere".utf8).write(to: repository.appending(path: ".git"))
        try Data().write(to: script)
        let log = directory.url.appending(path: "sync.log")
        try Data().write(to: log)
        let line = "0 3 * * * \(script.path(percentEncoded: false)) > \(log.path(percentEncoded: false)) 2>&1"
        let job = MonitoredItem.CronJob(
            line: line,
            expression: "0 3 * * *",
            command: "\(script.path(percentEncoded: false)) > \(log.path(percentEncoded: false)) 2>&1",
            schedule: nil,
            isReboot: false,
            standardOutPath: log.path(percentEncoded: false),
            standardErrorPath: log.path(percentEncoded: false),
            lastRun: nil,
            firstPath: script.path(percentEncoded: false)
        )
        let item = MonitoredItem(key: line, name: "sync.sh", status: .warning(reason: "Didn't run as scheduled"), detail: .cronJob(job))

        let prompt = await AIPrompt.make(for: item, home: directory.url, fileManager: .default)

        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "cd \(repository.path(percentEncoded: false).trimmingSuffix("/"))")
        #expect(prompt.contains("problem with the cron job below"))
        #expect(lines.contains("crontab line: \(line)"))
        #expect(lines.contains("Script: \(script.path(percentEncoded: false))"))
        #expect(lines.contains("Log: \(log.path(percentEncoded: false)) (empty)"))
        #expect(!prompt.contains("Label:"))
    }

    /// スクリプトの分からない cron の行は、どこで開くかを決められないので cd を付けない
    @Test func cronWithoutScriptHasNoWorkingDirectory() async {
        let job = MonitoredItem.CronJob(
            line: "@reboot echo hi",
            expression: "@reboot",
            command: "echo hi",
            schedule: nil,
            isReboot: true,
            standardOutPath: nil,
            standardErrorPath: nil,
            lastRun: nil,
            firstPath: nil
        )
        let item = MonitoredItem(key: job.line, name: "echo", status: .failed(reason: "Exit code 1"), detail: .cronJob(job))

        let prompt = await AIPrompt.make(for: item, home: URL(filePath: "/Users/me"), fileManager: .default)

        #expect(!prompt.hasPrefix("cd "))
        #expect(prompt.hasSuffix("No log files are configured."))
    }

    @Test(arguments: [
        ("/Users/me/dev/x", "/Users/me/dev/x"),
        ("/Users/me/My Scripts", "'/Users/me/My Scripts'"),
        ("it's", #"'it'\''s'"#),
    ])
    func shellQuotingOnlyWhenNeeded(text: String, quoted: String) {
        #expect(AIPrompt.shellQuoted(text) == quoted)
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }

    /// 正常な項目は問題の調査ではなく今の状態の見立てを頼み、画面の値を英語の書式で渡す
    @Test func healthyNetworkAsksForAssessment() async {
        let prompt = await AIPrompt.make(for: MonitoredItem.sampleNetwork)
        #expect(prompt.contains("shows the current state of the network health check below"))
        #expect(!prompt.contains("reports a problem"))
        #expect(prompt.contains("Ping 1.1.1.1: 13 ms, 0% loss"))
        #expect(prompt.contains("Last speed test: down 146 Mbps, up 132 Mbps"))
    }

    /// 負荷は原因のアプリといつからを、ストレージは場所ごとの大きさと増えた分を渡す
    @Test func loadAndStoragePromptsCarryTheCause() async {
        let load = await AIPrompt.make(for: MonitoredItem.sampleSystemLoad)
        #expect(load.contains("reports a problem with the system load check below"))
        #expect(load.contains("  Example Reel: 68%"))
        #expect(load.contains("High usage started: "))

        let storage = await AIPrompt.make(for: MonitoredItem.sampleStorage)
        #expect(storage.contains("Startup disk: 82 GB available of 994 GB"))
        #expect(storage.contains("  /Users/me/Library/Developer/Xcode/DerivedData: 148 GB, +36 GB since previous"))
    }
}
