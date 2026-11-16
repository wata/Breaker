import Foundation

/**
 `ping -q` の出力の解釈。終了コードは ping(8) の EXIT STATUS のとおり、0 は応答あり、2 は送れたが応答なし、それ以外はエラー
 （名前を引けないときは 68 で、標準出力には何も出ない）。応答が無いと round-trip の行は出ないので、平均は nil になる
 */
enum PingOutput {
    struct Summary: Hashable, Sendable {
        let transmitted: Int
        let received: Int
        /// 0〜100 の百分率。ping が出す値（小数1桁）をそのまま使う
        let packetLossPercent: Double
        /// 応答が無いときは nil
        let averageMilliseconds: Double?
    }

    enum ParseError: Error, Equatable {
        /// 0・2 以外の終了コード（名前を引けないときは 68）
        case failed(status: Int32)
        /// 終了コードは 0・2 なのに統計の行が無い
        case missingStatistics
    }

    static func parse(stdout: String, status: Int32) throws(ParseError) -> Summary {
        guard status == 0 || status == 2 else {
            throw .failed(status: status)
        }
        // 重複した応答があると received と loss の間に `+1 duplicates,` が入る
        guard
            let statistics = stdout.firstMatch(of: /(\d+) packets transmitted, (\d+) packets received,(?: \+\d+ duplicates,)? ([\d.]+)% packet loss/),
            let transmitted = Int(statistics.1),
            let received = Int(statistics.2),
            let loss = Double(statistics.3)
        else {
            throw .missingStatistics
        }
        let average = stdout
            .firstMatch(of: /round-trip min\/avg\/max\/stddev = [\d.]+\/([\d.]+)\/[\d.]+\/[\d.]+ ms/)
            .flatMap { Double($0.1) }
        return Summary(transmitted: transmitted, received: received, packetLossPercent: loss, averageMilliseconds: average)
    }
}
