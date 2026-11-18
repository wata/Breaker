import Foundation

/// 起動ディスクの空きと、膨らみやすい場所の最新の走査結果。空きはチェックごとに、走査は間隔を空けて測る。走査の結果は AI に渡すプロンプトの材料にする
struct StorageUsage: Hashable, Sendable {
    let capacityBytes: Int64
    /// 消してよいキャッシュ（パージ可能な領域）も空きに含めた、Finder と同じ値
    let availableBytes: Int64
    let scan: StorageScan?

    var availableShare: Double {
        capacityBytes > 0 ? Double(availableBytes) / Double(capacityBytes) : 1
    }
}

/**
 膨らみやすい場所を測った結果。前回の走査と比べて増えた分も持ち、何が膨らんだかを指せるようにする。
 起動し直しても前回の結果と比べられるよう、UserDefaults に JSON で残す
 */
struct StorageScan: Codable, Hashable, Sendable {
    struct Location: Codable, Hashable, Sendable {
        let location: StorageLocation
        /// Finder で見せる場所。複数のフォルダをまとめた場所では、その親
        let path: String
        let bytes: Int64
        /// 前回の走査での大きさ。前回が無い・前回は無かった場所は nil
        let previousBytes: Int64?

        var growthBytes: Int64? {
            previousBytes.map { bytes - $0 }
        }
    }

    let date: Date
    /// 比べた前回の走査の時刻。初めての走査では nil
    let previousDate: Date?
    /// 大きい順
    let locations: [Location]
}
