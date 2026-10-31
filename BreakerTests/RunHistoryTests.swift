import Foundation
import Testing
@testable import Breaker

struct RunHistoryTests {
    typealias Record = RunHistory.Record

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func firstObservationStartsWatchingWithoutRun() {
        #expect(RunHistory.updated(nil, runs: 44, now: start) == record(runs: 44, observedAt: start))
    }

    @Test func unchangedRunsKeepLastObservedRun() {
        let now = start.addingTimeInterval(60)
        #expect(RunHistory.updated(record(runs: 44, observedAt: start), runs: 44, now: now) == record(runs: 44, observedAt: now))
    }

    /// 実行は、それを見た1つ前に取り直した時刻より後に始まっている
    @Test func increasedRunsAreRun() {
        let previous = start.addingTimeInterval(1740)
        let now = start.addingTimeInterval(1800)
        #expect(
            RunHistory.updated(record(runs: 44, observedAt: previous), runs: 45, now: now)
                == record(runs: 45, observedAt: now, lastObservedRun: now, lastRunNotBefore: previous)
        )
    }

    /// reload で runs が数え直されて減ったときも、実行とみなす
    @Test func decreasedRunsAfterReloadAreRun() {
        let now = start.addingTimeInterval(120)
        #expect(
            RunHistory.updated(record(runs: 44, observedAt: start), runs: 1, now: now)
                == record(runs: 1, observedAt: now, lastObservedRun: now, lastRunNotBefore: start)
        )
    }

    /// 未ロードになったら忘れ、読み込み直したらそこから見張り直す
    @Test func unloadedJobIsForgotten() async {
        let history = RunHistory()
        _ = await history.observe(key: "a", runs: 3, now: start)
        #expect(await history.observe(key: "a", runs: nil, now: start.addingTimeInterval(60)) == nil)
        let reloaded = start.addingTimeInterval(120)
        #expect(await history.observe(key: "a", runs: 0, now: reloaded) == Record(watchStart: reloaded, runs: 0, lastObservedRun: nil, lastObservation: reloaded, lastRunNotBefore: nil))
    }

    private func record(runs: Int, observedAt: Date, lastObservedRun: Date? = nil, lastRunNotBefore: Date? = nil) -> Record {
        Record(watchStart: start, runs: runs, lastObservedRun: lastObservedRun, lastObservation: observedAt, lastRunNotBefore: lastRunNotBefore)
    }
}
