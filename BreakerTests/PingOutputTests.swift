import Testing
@testable import Breaker

struct PingOutputTests {
    /// `ping -q -c 3 -i 0.2 -t 3 1.1.1.1` の実際の出力（終了コード 0）
    @Test func allReceived() throws {
        let summary = try PingOutput.parse(stdout: try fixture("ping-all-received"), status: 0)
        #expect(summary == PingOutput.Summary(transmitted: 3, received: 3, packetLossPercent: 0, averageMilliseconds: 54.591))
    }

    /// 実際の全応答の出力の数を書き換えたもの。一部だけ返ったときも終了コードは 0
    @Test func someReceived() throws {
        let summary = try PingOutput.parse(stdout: try fixture("ping-some-received"), status: 0)
        #expect(summary == PingOutput.Summary(transmitted: 3, received: 2, packetLossPercent: 33.3, averageMilliseconds: 54.591))
    }

    /// `192.0.2.1`（TEST-NET）宛ての実際の出力（終了コード 2）。round-trip の行が無い
    @Test func noneReceived() throws {
        let summary = try PingOutput.parse(stdout: try fixture("ping-none-received"), status: 2)
        #expect(summary == PingOutput.Summary(transmitted: 3, received: 0, packetLossPercent: 100, averageMilliseconds: nil))
    }

    /// 存在しないホスト名（終了コード 68、標準出力は空）
    @Test func unknownHost() {
        #expect(throws: PingOutput.ParseError.failed(status: 68)) {
            try PingOutput.parse(stdout: "", status: 68)
        }
    }

    @Test func duplicatesAreSkipped() throws {
        let stdout = "3 packets transmitted, 3 packets received, +1 duplicates, 0.0% packet loss\nround-trip min/avg/max/stddev = 1.0/2.5/4.0/1.0 ms\n"
        let summary = try PingOutput.parse(stdout: stdout, status: 0)
        #expect(summary == PingOutput.Summary(transmitted: 3, received: 3, packetLossPercent: 0, averageMilliseconds: 2.5))
    }

    @Test func missingStatistics() {
        #expect(throws: PingOutput.ParseError.missingStatistics) {
            try PingOutput.parse(stdout: "PING 1.1.1.1 (1.1.1.1): 56 data bytes\n", status: 2)
        }
    }
}
