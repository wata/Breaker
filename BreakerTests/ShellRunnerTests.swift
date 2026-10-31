import Testing
@testable import Breaker

struct ShellRunnerTests {
    @Test func capturesStdoutStderrAndStatus() async throws {
        let output = try await ShellRunner().run("/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"])
        #expect(output == ShellOutput(status: 3, stdout: "out\n", stderr: "err\n"))
    }

    /// 引数はシェルで解釈されずにそのまま渡る
    @Test func passesArgumentsVerbatim() async throws {
        let output = try await ShellRunner().run("/bin/echo", arguments: ["a b", "$HOME", ";", "*"])
        #expect(output.stdout == "a b $HOME ; *\n")
    }

    /// パイプのバッファ（64KB）を超える出力でも、stdout と stderr の両方を読み切って止まらない
    @Test(.timeLimit(.minutes(1))) func readsOutputLargerThanPipeBuffer() async throws {
        let output = try await ShellRunner().run("/bin/sh", arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' e >&2; head -c 200000 /dev/zero | tr '\\0' o"])
        #expect(output.status == 0)
        #expect(output.stdout.count == 200_000)
        #expect(output.stderr.count == 200_000)
    }

    @Test func throwsWhenExecutableIsMissing() async {
        await #expect(throws: (any Error).self) {
            try await ShellRunner().run("/nonexistent/command", arguments: [])
        }
    }
}
