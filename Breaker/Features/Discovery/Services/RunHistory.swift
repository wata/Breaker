import Foundation

/**
 launchd は最終実行時刻を持たず、正常なときにログへ何も書かないジョブもあるので、ログの更新時刻だけでは走ったか分からない。
 取り直すたびに `launchctl print` の runs を覚えておき、変わったのを見た時刻を「実行を見た時刻」とする。
 reload で runs が 0 に戻ることがあるので、増えたときだけでなく変わったときも実行とみなす。
 runs は launchd の読み込み直しや Mac の再起動で数え直されるので、保存せずアプリの終了とともに捨てる
 */
actor RunHistory {
    struct Record: Equatable, Sendable {
        /// ロードされているのを最初に見た時刻。これより前の予定は、走ったかどうかを確かめようがない
        let watchStart: Date
        let runs: Int
        /// nil は見張りを始めてから一度も実行を見ていないこと
        let lastObservedRun: Date?
        /// 次に runs の変化を見たとき、その実行はこの時刻より後に始まっている
        let lastObservation: Date
        /**
         最後の実行が始まったのはこれより後（実行を見た1つ前に取り直した時刻）。これより前に書かれたログは前の実行のもの。
         launchd は起動のたびにログを追記で開くだけで更新時刻を変えないので、正常なときに何も書かないジョブの標準エラーには、
         直した後も前の失敗が残り続ける
         */
        let lastRunNotBefore: Date?
    }

    private var records: [String: Record] = [:]

    /// key は項目の ID の元。同じラベルが `~/Library/LaunchAgents` と `/Library/LaunchAgents` にあっても別のジョブとして覚える
    func observe(key: String, runs: Int?, now: Date) -> Record? {
        let record = Self.updated(records[key], runs: runs, now: now)
        records[key] = record
        return record
    }

    /// 未ロード（runs が nil）のジョブは忘れる。読み込み直したら、そこから見張り直す
    static func updated(_ record: Record?, runs: Int?, now: Date) -> Record? {
        guard let runs else {
            return nil
        }
        guard let record else {
            return Record(watchStart: now, runs: runs, lastObservedRun: nil, lastObservation: now, lastRunNotBefore: nil)
        }
        let didRun = runs != record.runs
        return Record(
            watchStart: record.watchStart,
            runs: runs,
            lastObservedRun: didRun ? now : record.lastObservedRun,
            lastObservation: now,
            lastRunNotBefore: didRun ? record.lastObservation : record.lastRunNotBefore
        )
    }
}
