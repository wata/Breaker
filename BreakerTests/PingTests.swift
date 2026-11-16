import Foundation
import Testing
@testable import Breaker

struct PingTests {
    @Test func passesArgumentsAndTimeout() async throws {
        let shell = StubShell(output: ShellOutput(status: 0, stdout: try fixture("ping-all-received"), stderr: ""))
        _ = try await Ping(shell: shell).ping("1.1.1.1")
        #expect(shell.calls == [
            StubShell.Call(
                executable: "/sbin/ping",
                arguments: ["-q", "-c", "10", "-i", "0.2", "-t", "4", "1.1.1.1"],
                timeout: .seconds(6)
            ),
        ])
    }

    @Test func allReceived() async throws {
        let shell = StubShell(output: ShellOutput(status: 0, stdout: try fixture("ping-all-received"), stderr: ""))
        let result = try await Ping(shell: shell).ping("1.1.1.1")
        #expect(result == NetworkHealth.PingResult(destination: "1.1.1.1", receivedCount: 3, lossRate: 0, averageMilliseconds: 54.591))
    }

    /// ping の出すロス率は百分率なので、0〜1 に直す
    @Test func convertsLossPercentToRate() async throws {
        let shell = StubShell(output: ShellOutput(status: 0, stdout: try fixture("ping-some-received"), stderr: ""))
        let result = try await Ping(shell: shell).ping("1.1.1.1")
        #expect(result.receivedCount == 2)
        #expect(abs(result.lossRate - 0.333) < 1e-9)
    }

    /// 終了コード 2（送れたが応答なし）
    @Test func noneReceived() async throws {
        let shell = StubShell(output: ShellOutput(status: 2, stdout: try fixture("ping-none-received"), stderr: ""))
        let result = try await Ping(shell: shell).ping("192.0.2.1")
        #expect(result == NetworkHealth.PingResult(destination: "192.0.2.1", receivedCount: 0, lossRate: 1, averageMilliseconds: nil))
    }

    /// 名前を引けない（68）・時間切れ・統計の無い出力は、どれも受信0として返す
    @Test(arguments: [
        ShellOutput(status: 68, stdout: "", stderr: "ping: cannot resolve no-such-host.invalid: Unknown host\n"),
        ShellOutput(status: 64, stdout: "", stderr: "usage: ping ...\n"),
        ShellOutput(status: 2, stdout: "PING 1.1.1.1 (1.1.1.1): 56 data bytes\n", stderr: ""),
    ])
    func failureIsNoneReceived(output: ShellOutput) async throws {
        let result = try await Ping(shell: StubShell(output: output)).ping("no-such-host.invalid")
        #expect(result == NetworkHealth.PingResult(destination: "no-such-host.invalid", receivedCount: 0, lossRate: 1, averageMilliseconds: nil))
    }

    @Test func timeoutIsNoneReceived() async throws {
        let shell = ThrowingShell(error: ShellError.timedOut(executable: "/sbin/ping"))
        let result = try await Ping(shell: shell).ping("1.1.1.1")
        #expect(result == NetworkHealth.PingResult(destination: "1.1.1.1", receivedCount: 0, lossRate: 1, averageMilliseconds: nil))
    }

    @Test func cancellationIsThrown() async {
        await #expect(throws: CancellationError.self) {
            try await Ping(shell: ThrowingShell(error: CancellationError())).ping("1.1.1.1")
        }
    }
}
