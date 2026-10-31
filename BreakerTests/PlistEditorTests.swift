import Foundation
import Testing
@testable import Breaker

/// plist・バックアップ・LaunchAgents はすべて一時ディレクトリに作る。launchctl と plutil はスタブで受ける
@MainActor
struct PlistEditorTests {
    private nonisolated static let original = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <!-- 30分ごとに取り込む -->
            <key>Label</key>
            <string>com.example.job</string>
            <key>ProgramArguments</key>
            <array>
                <string>/Users/example/dev/run.sh</string>
            </array>
            <key>StartInterval</key>
            <integer>1800</integer>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """

    private static let weekdays = Schedule(calendarEntries: (1...5).map { .init(minute: 0, hour: 9, weekday: $0) })
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func rewritesScheduleAndKeepsOtherKeys() async throws {
        let sandbox = try Sandbox()
        let plistURL = try sandbox.writePlist()
        let shell = Self.shell(isLoaded: false)

        try await sandbox.editor(shell: shell).save(Self.weekdays, for: .stub(plistURL: plistURL), now: Self.now)

        let plist = try Self.read(plistURL)
        #expect(Schedule(plist: plist).calendarEntries == Self.weekdays.calendarEntries)
        #expect(plist["StartInterval"] == nil)
        #expect(plist["Label"] as? String == "com.example.job")
        #expect(plist["ProgramArguments"] as? [String] == ["/Users/example/dev/run.sh"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(try String(contentsOf: plistURL, encoding: .utf8).hasPrefix("<?xml"))
    }

    @Test func backsUpOriginalBeforeWriting() async throws {
        let sandbox = try Sandbox()
        let plistURL = try sandbox.writePlist()

        try await sandbox.editor(shell: Self.shell(isLoaded: false)).save(Self.weekdays, for: .stub(plistURL: plistURL), now: Self.now)

        let backups = try FileManager.default.contentsOfDirectory(atPath: sandbox.backups.path(percentEncoded: false))
        let stamp = Self.stamp(Self.now)
        #expect(backups == ["com.example.job-\(stamp).plist"])
        #expect(try String(contentsOf: sandbox.backups.appending(path: backups[0]), encoding: .utf8) == Self.original)
    }

    /// リポジトリ内の plist を指すリンクは残し、リンク先を書き換える
    @Test func writesSymlinkTargetAndKeepsLink() async throws {
        let sandbox = try Sandbox()
        let targetURL = try sandbox.writePlist(at: sandbox.root.appending(path: "repo/job.plist"))
        let linkURL = sandbox.agents.appending(path: "com.example.job.plist")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        try await sandbox.editor(shell: Self.shell(isLoaded: false)).save(Self.weekdays, for: .stub(plistURL: linkURL), now: Self.now)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path(percentEncoded: false)) == targetURL.path(percentEncoded: false))
        #expect(Schedule(plist: try Self.read(targetURL)).calendarEntries.count == 5)
    }

    @Test func preservesPermissions() async throws {
        let sandbox = try Sandbox()
        let plistURL = try sandbox.writePlist()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path(percentEncoded: false))

        try await sandbox.editor(shell: Self.shell(isLoaded: false)).save(Self.weekdays, for: .stub(plistURL: plistURL), now: Self.now)

        let attributes = try FileManager.default.attributesOfItem(atPath: plistURL.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func lintFailureLeavesOriginalUntouched() async throws {
        let sandbox = try Sandbox()
        let plistURL = try sandbox.writePlist()
        let shell = StubShell { call in
            call.executable == "/usr/bin/plutil"
                ? ShellOutput(status: 1, stdout: "job.plist: Encountered unknown tag", stderr: "")
                : ShellOutput(status: 0, stdout: "", stderr: "")
        }

        await #expect(throws: PlistEditorError.lintFailed("job.plist: Encountered unknown tag")) {
            try await sandbox.editor(shell: shell).save(Self.weekdays, for: .stub(plistURL: plistURL), now: Self.now)
        }
        #expect(try String(contentsOf: plistURL, encoding: .utf8) == Self.original)
        #expect(!shell.calls.contains { $0.executable == "/bin/launchctl" })
    }

    /// lint は読むだけなので本物の plutil を通し、書き出した XML が launchd に読める形であることを確かめる
    @Test func writtenPlistPassesRealLint() async throws {
        let sandbox = try Sandbox()
        let plistURL = try sandbox.writePlist()
        let launchctlShell = Self.shell(isLoaded: false)
        let editor = PlistEditor(
            launchctl: LaunchctlService(shell: launchctlShell, uid: 501),
            shell: ShellRunner(),
            backupDirectory: sandbox.backups
        )

        try await editor.save(Self.weekdays, for: .stub(plistURL: plistURL), now: Self.now)

        #expect(Schedule(plist: try Self.read(plistURL)).calendarEntries.count == 5)
    }

    @Test func reloadsLoadedJobFromLinkPath() async throws {
        let sandbox = try Sandbox()
        let targetURL = try sandbox.writePlist(at: sandbox.root.appending(path: "repo/job.plist"))
        let linkURL = sandbox.agents.appending(path: "com.example.job.plist")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        let shell = Self.shell(isLoaded: true)

        try await sandbox.editor(shell: shell).save(Self.weekdays, for: .stub(plistURL: linkURL), now: Self.now)

        #expect(Self.launchctlArguments(shell) == [
            ["print", "gui/501/com.example.job"],
            ["bootout", "gui/501/com.example.job"],
            ["print", "gui/501/com.example.job"],
            ["bootstrap", "gui/501", linkURL.path(percentEncoded: false)],
        ])
    }

    /// bootout 直後はまだサービスが残っていて、そこで bootstrap すると Input/output error になる。消えたのを見てから読み込む
    @Test func reloadWaitsForBootoutBeforeBootstrapping() async throws {
        let sandbox = try Sandbox()
        let plistURL = try sandbox.writePlist()
        let shell = StubShell.launchctl(isLoaded: true, printsLoadedAfterBootout: 1)
        let editor = PlistEditor(
            launchctl: LaunchctlService(shell: shell, uid: 501) { _ in },
            shell: shell,
            backupDirectory: sandbox.backups
        )

        try await editor.save(Self.weekdays, for: .stub(plistURL: plistURL), now: Self.now)

        #expect(Self.launchctlArguments(shell) == [
            ["print", "gui/501/com.example.job"],
            ["bootout", "gui/501/com.example.job"],
            ["print", "gui/501/com.example.job"],
            ["print", "gui/501/com.example.job"],
            ["bootstrap", "gui/501", plistURL.path(percentEncoded: false)],
        ])
    }

    @Test func unloadedJobIsOnlyWritten() async throws {
        let sandbox = try Sandbox()
        let plistURL = try sandbox.writePlist()
        let shell = Self.shell(isLoaded: false)

        try await sandbox.editor(shell: shell).save(Self.weekdays, for: .stub(plistURL: plistURL), now: Self.now)

        #expect(Self.launchctlArguments(shell) == [["print", "gui/501/com.example.job"]])
    }

    @Test(arguments: [(true, false), (false, true)])
    func disabledJobIsOnlyWritten(isDisabledFile: Bool, isDisabledLabel: Bool) async throws {
        let sandbox = try Sandbox()
        let plistURL = try sandbox.writePlist(at: sandbox.agents.appending(path: "com.example.job.plist\(isDisabledFile ? ".disabled" : "")"))
        let shell = Self.shell(isLoaded: true)
        let job = MonitoredItem.LaunchdJob.stub(plistURL: plistURL, isDisabledFile: isDisabledFile, isDisabledLabel: isDisabledLabel)

        try await sandbox.editor(shell: shell).save(Self.weekdays, for: job, now: Self.now)

        #expect(Self.launchctlArguments(shell).isEmpty)
        #expect(Schedule(plist: try Self.read(plistURL)).calendarEntries.count == 5)
    }

    @Test func detectsCommentsThroughSymlink() throws {
        let sandbox = try Sandbox()
        let targetURL = try sandbox.writePlist(at: sandbox.root.appending(path: "repo/job.plist"))
        let linkURL = sandbox.agents.appending(path: "com.example.job.plist")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        let plainURL = try sandbox.writePlist(
            at: sandbox.agents.appending(path: "plain.plist"),
            contents: Self.original.replacingOccurrences(of: "<!-- 30分ごとに取り込む -->", with: "")
        )

        #expect(PlistEditor.containsComments(at: linkURL))
        #expect(!PlistEditor.containsComments(at: plainURL))
        #expect(!PlistEditor.containsComments(at: sandbox.agents.appending(path: "missing.plist")))
    }

    private static func shell(isLoaded: Bool) -> StubShell {
        .launchctl(isLoaded: isLoaded)
    }

    private static func launchctlArguments(_ shell: StubShell) -> [[String]] {
        shell.calls.filter { $0.executable == "/bin/launchctl" }.map(\.arguments)
    }

    private static func read(_ url: URL) throws -> [String: Any] {
        try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// LaunchAgents とバックアップ先を一時ディレクトリの中に用意する
    private struct Sandbox: ~Copyable {
        let directory: TemporaryDirectory

        init() throws {
            let directory = try TemporaryDirectory()
            try FileManager.default.createDirectory(
                at: directory.url.appending(path: "LaunchAgents", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
            self.directory = directory
        }

        var root: URL {
            directory.url
        }

        var agents: URL {
            root.appending(path: "LaunchAgents", directoryHint: .isDirectory)
        }

        var backups: URL {
            root.appending(path: "backups", directoryHint: .isDirectory)
        }

        @discardableResult
        func writePlist(at url: URL? = nil, contents: String = PlistEditorTests.original) throws -> URL {
            let url = url ?? agents.appending(path: "com.example.job.plist")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            return url
        }

        @MainActor
        func editor(shell: StubShell) -> PlistEditor {
            PlistEditor(launchctl: LaunchctlService(shell: shell, uid: 501), shell: shell, backupDirectory: backups)
        }
    }
}
