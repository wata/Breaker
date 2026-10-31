import Foundation

/**
 launchd は最終実行時刻を持たず、正常なときにログへ何も書かないジョブもあるので、ログの更新時刻だけでは走ったか分からない。
 取り直すたびに `launchctl print` の runs を覚えておき、変わったのを見た時刻を「実行を見た時刻」とする。
 reload で runs が 0 に戻ることがあるので、増えたときだけでなく変わったときも実行とみなす。
 見張りの記録はアプリの終了とともに捨てる（閉じていた間の予定は、走ったかどうかを確かめようがない）。
 ただし古いログを見分けるための runs と時刻だけは保存して次の起動に引き継ぎ、アップデートや再起動のたびに直した後の失敗を出し直さない
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

    /// 前回の起動で最後に見た runs と時刻。`Record` のうち古いログを見分けるのに要るものだけ
    struct Saved: Codable, Equatable, Sendable {
        let runs: Int
        let lastObservation: Date
        let lastRunNotBefore: Date?
    }

    /// 項目の ID の元をキーにした `Saved` の辞書（JSON）を UserDefaults に入れておくキー
    static let savedKey = "runHistory"

    private var records: [String: Record] = [:]
    private var saved: [String: Saved]
    /// nil なら保存しない。テストで実際のアプリの設定に書き込まないため
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        saved = defaults?.data(forKey: Self.savedKey).flatMap { try? JSONDecoder().decode([String: Saved].self, from: $0) } ?? [:]
    }

    /// key は項目の ID の元。同じラベルが `~/Library/LaunchAgents` と `/Library/LaunchAgents` にあっても別のジョブとして覚える
    func observe(key: String, runs: Int?, now: Date) -> Record? {
        let record = Self.updated(records[key], saved: saved[key], runs: runs, now: now)
        records[key] = record
        saved[key] = record.map { Saved(runs: $0.runs, lastObservation: $0.lastObservation, lastRunNotBefore: $0.lastRunNotBefore) }
        defaults?.set(try? JSONEncoder().encode(saved), forKey: Self.savedKey)
        return record
    }

    /**
     未ロード（runs が nil）のジョブは忘れる。読み込み直したら、そこから見張り直す。
     起動して初めて見たときは、前回の終了までに見た runs から変わっていれば、その実行は前回最後に見た時刻より後に始まっている。
     Mac の再起動で runs が数え直されて偶然同じになっても、前回の下限を引き継ぐだけなので古いログを見落とす側にはずれない
     */
    static func updated(_ record: Record?, saved: Saved?, runs: Int?, now: Date) -> Record? {
        guard let runs else {
            return nil
        }
        guard let record else {
            return Record(
                watchStart: now,
                runs: runs,
                lastObservedRun: nil,
                lastObservation: now,
                lastRunNotBefore: saved.flatMap { $0.runs == runs ? $0.lastRunNotBefore : $0.lastObservation }
            )
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
