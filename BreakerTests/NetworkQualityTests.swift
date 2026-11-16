import Foundation
import Testing
@testable import Breaker

struct NetworkQualityTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func measure(_ shell: any ShellRunning) async throws -> SpeedTestRecord {
        try await NetworkQuality(shell: shell, now: { now }).measure()
    }

    @Test func passesArgumentsAndTimeout() async throws {
        let shell = StubShell(output: ShellOutput(status: 0, stdout: try fixture("networkquality-c"), stderr: ""))
        _ = try await Self.measure(shell)
        #expect(shell.calls == [
            StubShell.Call(executable: "/usr/bin/networkQuality", arguments: ["-c", "-M", "10"], timeout: .seconds(30)),
        ])
    }

    /// 日付は計測の終わり（`end_date`）
    @Test func succeeded() async throws {
        let stdout = try fixture("networkquality-c")
        let record = try await Self.measure(StubShell(output: ShellOutput(status: 0, stdout: stdout, stderr: "")))
        let parsed = try NetworkQualityOutput.parse(Data(stdout.utf8))
        let speed = SpeedTestRecord.Speed(
            downloadBitsPerSecond: 232_652_336,
            uploadBitsPerSecond: 118_548_984,
            responsiveness: 797.47509765625,
            baseRoundTripMilliseconds: 11.983421325683594
        )
        #expect(record == SpeedTestRecord(date: try #require(parsed.endDate), outcome: .succeeded(speed)))
    }

    @Test func withoutEndDateUsesNow() async throws {
        let stdout = #"{"dl_throughput": 1000, "ul_throughput": 500}"#
        let record = try await Self.measure(StubShell(output: ShellOutput(status: 0, stdout: stdout, stderr: "")))
        let speed = SpeedTestRecord.Speed(
            downloadBitsPerSecond: 1000,
            uploadBitsPerSecond: 500,
            responsiveness: nil,
            baseRoundTripMilliseconds: nil
        )
        #expect(record == SpeedTestRecord(date: Self.now, outcome: .succeeded(speed)))
    }

    @Test func nonZeroExitFails() async throws {
        let record = try await Self.measure(StubShell(output: ShellOutput(status: 1, stdout: "", stderr: "Error: no network\n")))
        #expect(record == SpeedTestRecord(date: Self.now, outcome: .failed(reason: "networkQuality failed with exit code 1: Error: no network")))
    }

    @Test func nonZeroExitWithoutMessageFails() async throws {
        let record = try await Self.measure(StubShell(output: ShellOutput(status: 1, stdout: "", stderr: "")))
        #expect(record == SpeedTestRecord(date: Self.now, outcome: .failed(reason: "networkQuality failed with exit code 1")))
    }

    @Test(arguments: [#"{"dl_throughput": 1"#, #"{"ul_throughput": 1}"#, ""])
    func unreadableOutputFails(stdout: String) async throws {
        let record = try await Self.measure(StubShell(output: ShellOutput(status: 0, stdout: stdout, stderr: "")))
        #expect(record == SpeedTestRecord(date: Self.now, outcome: .failed(reason: "Couldn't read the output of networkQuality")))
    }

    @Test func timeoutFails() async throws {
        let record = try await Self.measure(ThrowingShell(error: ShellError.timedOut(executable: "/usr/bin/networkQuality")))
        #expect(record == SpeedTestRecord(date: Self.now, outcome: .failed(reason: "networkQuality didn't finish within 30 seconds")))
    }

    @Test func otherErrorFails() async throws {
        let error = CocoaError(.fileNoSuchFile)
        let record = try await Self.measure(ThrowingShell(error: error))
        #expect(record == SpeedTestRecord(date: Self.now, outcome: .failed(reason: error.localizedDescription)))
    }

    @Test func cancellationIsThrown() async {
        await #expect(throws: CancellationError.self) {
            try await Self.measure(ThrowingShell(error: CancellationError()))
        }
    }
}
