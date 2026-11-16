import Foundation
import Testing
@testable import Breaker

struct NetworkQualityOutputTests {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// `networkQuality -c -M 5` の実際の出力から大きな配列（`il_*`・`lud_*`）を削ったもの
    @Test func parsesFixture() throws {
        let output = try NetworkQualityOutput.parse(Data(try fixture("networkquality-c").utf8), timeZone: tokyo)
        #expect(output.downloadThroughput == 232_652_336)
        #expect(output.uploadThroughput == 118_548_984)
        #expect(output.responsiveness == 797.47509765625)
        #expect(output.baseRoundTripTime == 11.983421325683594)
        #expect(isSame(output.endDate, "2026-11-16T05:54:35.063Z"))
    }

    @Test func brokenJSONIsInvalid() {
        #expect(throws: NetworkQualityOutput.ParseError.invalidJSON) {
            try NetworkQualityOutput.parse(Data("{\"dl_throughput\": 1".utf8))
        }
        #expect(throws: NetworkQualityOutput.ParseError.invalidJSON) {
            try NetworkQualityOutput.parse(Data())
        }
    }

    @Test(arguments: [
        #"{"ul_throughput": 1, "responsiveness": 100}"#,
        #"{"dl_throughput": 1, "responsiveness": 100}"#,
        #"{"dl_throughput": null, "ul_throughput": 1}"#,
        "{}",
    ])
    func missingThroughput(json: String) {
        #expect(throws: NetworkQualityOutput.ParseError.missingThroughput) {
            try NetworkQualityOutput.parse(Data(json.utf8))
        }
    }

    /// スループット以外は欠けても形が違っても、速度は読める
    @Test func optionalValuesMayBeMissingOrMalformed() throws {
        let output = try NetworkQualityOutput.parse(Data(#"{"dl_throughput": 1.5, "ul_throughput": 2, "start_date": "2026/11/16", "base_rtt": "fast"}"#.utf8))
        #expect(output.downloadThroughput == 1.5)
        #expect(output.uploadThroughput == 2)
        #expect(output.responsiveness == nil)
        #expect(output.baseRoundTripTime == nil)
        #expect(output.endDate == nil)
    }

    /// ミリ秒の解析は浮動小数の誤差が出うるので、1ms 未満の差は同じとみなす
    private func isSame(_ date: Date?, _ iso8601: String) -> Bool {
        guard
            let date,
            let expected = try? Date(iso8601, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))
        else {
            return false
        }
        return abs(date.timeIntervalSince(expected)) < 0.001
    }
}
