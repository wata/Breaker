import Foundation
import Testing
@testable import Breaker

struct LaunchctlServiceTests {
    @Test func parsesRunningKeepAliveJob() throws {
        let info = try #require(LaunchctlService.parsePrint(try fixture("launchctl-print-running")))
        #expect(info.state == "running")
        #expect(info.isRunning)
        #expect(info.pid == 87964)
        #expect(info.runs == 1)
        #expect(info.lastExit == .never)
    }

    /// 入れ子の coalition ブロックにある `state = active` を拾わないこと
    @Test func parsesExitedJobIgnoringNestedBlocks() throws {
        let info = try #require(LaunchctlService.parsePrint(try fixture("launchctl-print-exited")))
        #expect(info.state == "not running")
        #expect(!info.isRunning)
        #expect(info.pid == nil)
        #expect(info.runs == 1)
        #expect(info.lastExit == .code(0))
        #expect(!info.lastExit.isFailure)
    }

    @Test func parsesNonZeroExit() throws {
        let info = try #require(LaunchctlService.parsePrint(try fixture("launchctl-print-failed")))
        #expect(info.runs == 45)
        #expect(info.lastExit == .code(1))
        #expect(info.lastExit.isFailure)
    }

    @Test func parsesNeverExited() throws {
        let info = try #require(LaunchctlService.parsePrint(try fixture("launchctl-print-never-exited")))
        #expect(info.runs == 0)
        #expect(info.lastExit == .never)
        #expect(!info.lastExit.isFailure)
    }

    /// 実機では採取できなかった表記。実出力の該当行だけを差し替えて確かめる
    @Test(arguments: [
        ("last exit code = 78: EX_CONFIG", LaunchdServiceInfo.LastExit.code(78)),
        ("last exit code = -9", .signal(9)),
        ("last exit code = 0\n\tlast terminating signal = Killed: 9", .signal(9)),
    ])
    func parsesExitVariants(line: String, expected: LaunchdServiceInfo.LastExit) throws {
        let output = try fixture("launchctl-print-exited").replacingOccurrences(of: "last exit code = 0", with: line)
        let info = try #require(LaunchctlService.parsePrint(output))
        #expect(info.lastExit == expected)
        #expect(info.lastExit.isFailure)
    }

    @Test func returnsNilWhenServiceIsNotLoaded() async throws {
        let shell = StubShell(output: ShellOutput(status: 113, stdout: "", stderr: try fixture("launchctl-print-not-found")))
        let service = LaunchctlService(shell: shell, uid: 501)
        #expect(try await service.print(label: "does.not.exist") == nil)
        #expect(shell.calls == [StubShell.Call(executable: "/bin/launchctl", arguments: ["print", "gui/501/does.not.exist"])])
    }

    @Test func printParsesShellOutput() async throws {
        let shell = StubShell(output: ShellOutput(status: 0, stdout: try fixture("launchctl-print-running"), stderr: ""))
        let info = try await LaunchctlService(shell: shell, uid: 501).print(label: "com.example.web-server")
        #expect(info?.pid == 87964)
    }

    /// `/Library/LaunchDaemons` のジョブは system ドメインで読む
    @Test func readsSystemDomain() async throws {
        let shell = StubShell { call in
            call.arguments.first == "print-disabled"
                ? ShellOutput(status: 0, stdout: "disabled services = {\n\t\"com.example.helper\" => disabled\n}\n", stderr: "")
                : ShellOutput(status: 0, stdout: (try? fixture("launchctl-print-running")) ?? "", stderr: "")
        }
        let service = LaunchctlService(shell: shell, uid: 501)
        #expect(try await service.print(label: "com.example.helper", in: .system)?.pid == 87964)
        #expect(try await service.disabledLabels(in: .system) == ["com.example.helper"])
        #expect(shell.calls.map(\.arguments) == [["print", "system/com.example.helper"], ["print-disabled", "system"]])
    }

    @Test func throwsOnOtherFailures() async throws {
        let shell = StubShell(output: ShellOutput(status: 5, stdout: "", stderr: "Input/output error"))
        await #expect(throws: LaunchctlError.self) {
            try await LaunchctlService(shell: shell, uid: 501).kickstart(label: "com.example.cert-check")
        }
    }

    @Test func parsesDisabledLabels() throws {
        let disabled = LaunchctlService.parseDisabled(try fixture("launchctl-print-disabled"))
        #expect(disabled.contains("com.example.backup"))
        #expect(disabled.contains("com.elgato.StreamDeck"))
        #expect(!disabled.contains("com.ollama.ollama"))
        #expect(disabled.count == 6)
    }

    @Test func disabledLabelsRunsPrintDisabled() async throws {
        let shell = StubShell(output: ShellOutput(status: 0, stdout: try fixture("launchctl-print-disabled"), stderr: ""))
        let disabled = try await LaunchctlService(shell: shell, uid: 501).disabledLabels()
        #expect(disabled.count == 6)
        #expect(shell.calls.first?.arguments == ["print-disabled", "gui/501"])
    }

    /// bootout は非同期に終わるので、print で見つからなくなるまで待ってから戻る
    @Test func bootoutWaitsUntilServiceIsGone() async throws {
        let shell = StubShell.launchctl(isLoaded: true, printsLoadedAfterBootout: 2)
        let sleeps = SleepRecorder()

        try await LaunchctlService(shell: shell, uid: 501, sleep: sleeps.record).bootout(label: "com.example.job")

        #expect(shell.arguments == [
            ["bootout", "gui/501/com.example.job"],
            ["print", "gui/501/com.example.job"],
            ["print", "gui/501/com.example.job"],
            ["print", "gui/501/com.example.job"],
        ])
        #expect(sleeps.durations == [.milliseconds(100), .milliseconds(100)])
    }

    /// 消えないまま待ちきれなくても失敗にはせず、5秒ほどで諦める
    @Test func bootoutGivesUpAfterTimeout() async throws {
        let shell = StubShell.launchctl(isLoaded: true, printsLoadedAfterBootout: .max)
        let sleeps = SleepRecorder()

        try await LaunchctlService(shell: shell, uid: 501, sleep: sleeps.record).bootout(label: "com.example.job")

        #expect(shell.arguments.count { $0.first == "print" } == 50)
        #expect(sleeps.durations.reduce(.zero, +) == .seconds(5))
    }

    @Test func bootoutFailureSkipsWaiting() async throws {
        let shell = StubShell(output: ShellOutput(status: 5, stdout: "", stderr: "Input/output error"))
        let sleeps = SleepRecorder()

        await #expect(throws: LaunchctlError.self) {
            try await LaunchctlService(shell: shell, uid: 501, sleep: sleeps.record).bootout(label: "com.example.job")
        }
        #expect(shell.arguments == [["bootout", "gui/501/com.example.job"]])
        #expect(sleeps.durations.isEmpty)
    }
}

/// 実際には待たず、待とうとした長さだけを記録する
private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [Duration]()

    var durations: [Duration] {
        lock.withLock { recorded }
    }

    func record(_ duration: Duration) async throws {
        lock.withLock { recorded.append(duration) }
    }
}
