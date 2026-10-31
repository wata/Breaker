import Foundation
import Testing
@testable import Breaker

struct RunHistoryTests {
    typealias Record = RunHistory.Record

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func firstObservationStartsWatchingWithoutRun() {
        #expect(RunHistory.updated(nil, runs: 44, now: start) == Record(watchStart: start, runs: 44, lastObservedRun: nil))
    }

    @Test func unchangedRunsKeepLastObservedRun() {
        let record = Record(watchStart: start, runs: 44, lastObservedRun: nil)
        #expect(RunHistory.updated(record, runs: 44, now: start.addingTimeInterval(60)) == record)
    }

    @Test func increasedRunsAreRun() {
        let record = Record(watchStart: start, runs: 44, lastObservedRun: nil)
        let now = start.addingTimeInterval(1800)
        #expect(RunHistory.updated(record, runs: 45, now: now) == Record(watchStart: start, runs: 45, lastObservedRun: now))
    }

    /// reload で runs が数え直されて減ったときも、実行とみなす
    @Test func decreasedRunsAfterReloadAreRun() {
        let record = Record(watchStart: start, runs: 44, lastObservedRun: nil)
        let now = start.addingTimeInterval(120)
        #expect(RunHistory.updated(record, runs: 1, now: now) == Record(watchStart: start, runs: 1, lastObservedRun: now))
    }

    /// 未ロードになったら忘れ、読み込み直したらそこから見張り直す
    @Test func unloadedJobIsForgotten() async {
        let history = RunHistory()
        _ = await history.observe(key: "a", runs: 3, now: start)
        #expect(await history.observe(key: "a", runs: nil, now: start.addingTimeInterval(60)) == nil)
        let reloaded = start.addingTimeInterval(120)
        #expect(await history.observe(key: "a", runs: 0, now: reloaded) == Record(watchStart: reloaded, runs: 0, lastObservedRun: nil))
    }
}
