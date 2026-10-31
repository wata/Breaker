import Foundation

/**
 cron の予定の時刻に Mac が起きていたかを `pmset -g log` で答える。この出力は数万〜数十万行あり、取るだけで 10 秒ほど CPU を使うので
 （実機で 183,806 行・約 10.5 秒）、取り直しをまたいで覚えておき、覚えている範囲より新しい時刻を聞かれたときだけ取り直す。
 過去の記録は後から変わらないので、取った時刻までの答えはそのまま使える。
 取っている間は待たずに「分からない」（起きていたとは言わない）と答え、一覧の取り直し全体を遅らせない。次の取り直しで答えが出る
 */
actor AwakeHistory {
    private struct Snapshot {
        let intervals: [PowerLog.Interval]
        /// ログを取った時刻。これより後のことは分からない
        let date: Date
    }

    /**
     取り直しの間隔の下限。予定の時刻が少しずつずれた候補が続いても `pmset` を何度も走らせないため。
     走っていない検出は予定から 15 分以上待ってから出すので、この分だけ遅れても困らない
     */
    static let minimumReloadInterval: TimeInterval = 15 * 60

    private let shell: any ShellRunning
    private var snapshot: Snapshot?
    private var loading: Task<Void, Never>?

    init(shell: any ShellRunning = ShellRunner()) {
        self.shell = shell
    }

    /// 覚えている範囲で答えられないときは false。必要なら裏で取り直しを始める
    func wasAwake(at date: Date, for duration: TimeInterval, now: Date) -> Bool {
        if
            let snapshot,
            date.addingTimeInterval(duration) <= snapshot.date
        {
            return PowerLog.isAwake(at: date, for: duration, in: snapshot.intervals)
        }
        if
            loading == nil,
            snapshot.map({ now.timeIntervalSince($0.date) >= Self.minimumReloadInterval }) ?? true
        {
            loading = Task {
                await fetch(now: now)
            }
        }
        return false
    }

    /// 取っている最中ならそれを待つ。`pmset` を重ねて走らせない
    func load(now: Date) async {
        if loading == nil {
            loading = Task {
                await fetch(now: now)
            }
        }
        await loading?.value
    }

    /**
     取れなかったときは区間を空で覚える（履歴が無いなら走っていないとは言わない）。間隔の下限までは取り直さない。
     取っている間にアクターへ入れるので、後から終わった古い結果で新しい結果を上書きしない
     */
    private func fetch(now: Date) async {
        let intervals = await Self.intervals(shell: shell, until: now)
        if snapshot.map({ $0.date < now }) ?? true {
            snapshot = Snapshot(intervals: intervals, date: now)
        }
        loading = nil
    }

    /// 数十 MB の出力を解釈する間、アクターを止めないよう外で行う
    @concurrent
    private static func intervals(shell: any ShellRunning, until end: Date) async -> [PowerLog.Interval] {
        guard
            let output = try? await shell.run("/usr/bin/pmset", arguments: ["-g", "log"]),
            output.status == 0
        else {
            return []
        }
        return PowerLog.awakeIntervals(in: output.stdout, until: end)
    }
}
