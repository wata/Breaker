import Foundation
import Testing
@testable import Breaker

/// 速度計測などが固まっても子プロセスを溜めないよう、時間切れとキャンセルで確実に止める
struct ShellRunnerStopTests {
    /// 子の pid を外から知るため、シェルに pid を書かせてから同じ pid のまま sleep に置き換える
    private static func sleepArguments(pidFile: URL, ignoringTerm: Bool = false) -> [String] {
        let trap = ignoringTerm ? "trap '' TERM; " : ""
        return ["-c", "\(trap)echo $$ > '\(pidFile.path(percentEncoded: false))'; exec /bin/sleep 30"]
    }

    private static func pid(in file: URL) throws -> pid_t {
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(pid_t(text))
    }

    private static func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    @Test(.timeLimit(.minutes(1))) func stopsProcessWhenTimedOut() async throws {
        let directory = try TemporaryDirectory()
        let pidFile = directory.url.appending(path: "pid")
        let start = ContinuousClock.now
        await #expect(throws: ShellError.timedOut(executable: "/bin/sh")) {
            try await ShellRunner().run("/bin/sh", arguments: Self.sleepArguments(pidFile: pidFile), timeout: .milliseconds(500))
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(Self.isGone(try Self.pid(in: pidFile)))
    }

    /// SIGTERM を無視するコマンドも SIGKILL で止める
    @Test(.timeLimit(.minutes(1))) func killsProcessIgnoringTerm() async throws {
        let directory = try TemporaryDirectory()
        let pidFile = directory.url.appending(path: "pid")
        await #expect(throws: ShellError.timedOut(executable: "/bin/sh")) {
            try await ShellRunner().run(
                "/bin/sh",
                arguments: Self.sleepArguments(pidFile: pidFile, ignoringTerm: true),
                timeout: .milliseconds(500)
            )
        }
        #expect(Self.isGone(try Self.pid(in: pidFile)))
    }

    @Test(.timeLimit(.minutes(1))) func stopsProcessWhenCancelled() async throws {
        let directory = try TemporaryDirectory()
        let pidFile = directory.url.appending(path: "pid")
        let arguments = Self.sleepArguments(pidFile: pidFile)
        let task = Task {
            try await ShellRunner().run("/bin/sh", arguments: arguments)
        }
        while !FileManager.default.fileExists(atPath: pidFile.path(percentEncoded: false)) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(Self.isGone(try Self.pid(in: pidFile)))
    }

    @Test func returnsOutputWhenFinishedInTime() async throws {
        let output = try await ShellRunner().run("/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: .seconds(10))
        #expect(output == ShellOutput(status: 3, stdout: "out\n", stderr: "err\n"))
    }

    /// 子が終わっても、パイプを継いだ孫が残っていれば読みを打ち切って返す
    @Test(.timeLimit(.minutes(1))) func returnsWhenGrandchildHoldsPipe() async throws {
        let start = ContinuousClock.now
        let output = try await ShellRunner().run("/bin/sh", arguments: ["-c", "echo out; /bin/sleep 5 & exit 0"])
        #expect(ContinuousClock.now - start < .seconds(4))
        #expect(output == ShellOutput(status: 0, stdout: "out\n", stderr: ""))
    }
}
