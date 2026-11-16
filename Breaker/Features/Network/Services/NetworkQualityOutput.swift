import Foundation

/**
 `networkQuality -c` が標準出力に出す JSON のうち、ヘルスチェックに使う値。
 速度の判定には上りと下りの両方が要るので、スループットはどちらかが無ければ解析エラーにする。
 それ以外の値は欠けても速度は出せるので optional にし、日付の形式が変わっただけで測定全体を捨てないようにする
 */
struct NetworkQualityOutput: Hashable, Sendable {
    enum ParseError: Error, Equatable {
        /// JSON として読めない、または値の型が合わない
        case invalidJSON
        /// スループットが無い（`dl_throughput`・`ul_throughput` のどちらかが欠けているか null）
        case missingThroughput
    }

    /// bit/s
    let downloadThroughput: Double
    /// bit/s
    let uploadThroughput: Double
    /// RPM（1分あたりの往復回数）
    let responsiveness: Double?
    /// 負荷をかけていないときの往復時間（ms）
    let baseRoundTripTime: Double?
    let endDate: Date?

    /// 日付は `2026-11-16 14:54:29.931` のようにタイムゾーン無しで、実測では Mac の現地時刻だった
    static func parse(_ data: Data, timeZone: TimeZone = .current) throws(ParseError) -> NetworkQualityOutput {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        do {
            return try decoder.decode(NetworkQualityOutput.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) where isThroughput(key) {
            throw .missingThroughput
        } catch let DecodingError.valueNotFound(_, context) where context.codingPath.last.map(isThroughput) ?? false {
            throw .missingThroughput
        } catch {
            throw .invalidJSON
        }
    }

    private static func isThroughput(_ key: any CodingKey) -> Bool {
        key.stringValue == CodingKeys.downloadThroughput.stringValue || key.stringValue == CodingKeys.uploadThroughput.stringValue
    }
}

extension NetworkQualityOutput: Decodable {
    enum CodingKeys: String, CodingKey {
        case downloadThroughput = "dl_throughput"
        case uploadThroughput = "ul_throughput"
        case responsiveness
        case baseRoundTripTime = "base_rtt"
        case endDate = "end_date"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadThroughput = try container.decode(Double.self, forKey: .downloadThroughput)
        uploadThroughput = try container.decode(Double.self, forKey: .uploadThroughput)
        responsiveness = try? container.decodeIfPresent(Double.self, forKey: .responsiveness)
        baseRoundTripTime = try? container.decodeIfPresent(Double.self, forKey: .baseRoundTripTime)
        endDate = try? container.decodeIfPresent(Date.self, forKey: .endDate)
    }
}
