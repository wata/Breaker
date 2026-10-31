import Foundation
import Testing
@testable import Breaker

struct RunHistoryTests {
    typealias Record = RunHistory.Record

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func firstObservationStartsWatchingWithoutRun() {
        #expect(RunHistory.updated(nil, saved: nil, runs: 44, now: start) == record(runs: 44, observedAt: start))
    }

    @Test func unchangedRunsKeepLastObservedRun() {
        let now = start.addingTimeInterval(60)
        #expect(RunHistory.updated(record(runs: 44, observedAt: start), saved: nil, runs: 44, now: now) == record(runs: 44, observedAt: now))
    }

    /// 実行は、それを見た1つ前に取り直した時刻より後に始まっている
    @Test func increasedRunsAreRun() {
        let previous = start.addingTimeInterval(1740)
        let now = start.addingTimeInterval(1800)
        #expect(
            RunHistory.updated(record(runs: 44, observedAt: previous), saved: nil, runs: 45, now: now)
                == record(runs: 45, observedAt: now, lastObservedRun: now, lastRunNotBefore: previous)
        )
    }

    /// reload で runs が数え直されて減ったときも、実行とみなす
    @Test func decreasedRunsAfterReloadAreRun() {
        let now = start.addingTimeInterval(120)
        #expect(
            RunHistory.updated(record(runs: 44, observedAt: start), saved: nil, runs: 1, now: now)
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

    /// 前回の終了までに見た runs から変わっていれば、その実行は前回最後に見た時刻より後に始まっている
    @Test func changedRunsSinceLastLaunchStartAfterSavedObservation() {
        let saved = RunHistory.Saved(runs: 44, lastObservation: start, lastRunNotBefore: nil)
        let now = start.addingTimeInterval(3600)
        #expect(
            RunHistory.updated(nil, saved: saved, runs: 46, now: now)
                == Record(watchStart: now, runs: 46, lastObservedRun: nil, lastObservation: now, lastRunNotBefore: start)
        )
    }

    /// 前回の終了から走っていなければ、前回の下限をそのまま引き継ぐ
    @Test func unchangedRunsSinceLastLaunchKeepSavedBound() {
        let bound = start.addingTimeInterval(-60)
        let saved = RunHistory.Saved(runs: 44, lastObservation: start, lastRunNotBefore: bound)
        let now = start.addingTimeInterval(3600)
        #expect(
            RunHistory.updated(nil, saved: saved, runs: 44, now: now)
                == Record(watchStart: now, runs: 44, lastObservedRun: nil, lastObservation: now, lastRunNotBefore: bound)
        )
    }

    /// 保存した runs と時刻は、同じ suite で作り直した RunHistory に引き継がれる
    @Test func savedRunsCarryOverToNextLaunch() async throws {
        let defaults = try IsolatedDefaults()
        let previous = RunHistory(defaults: defaults.userDefaults)
        _ = await previous.observe(key: "a", runs: 3, now: start)
        let next = RunHistory(defaults: try #require(UserDefaults(suiteName: defaults.suiteName)))
        let now = start.addingTimeInterval(600)
        #expect(await next.observe(key: "a", runs: 4, now: now)?.lastRunNotBefore == start)
    }

    private func record(runs: Int, observedAt: Date, lastObservedRun: Date? = nil, lastRunNotBefore: Date? = nil) -> Record {
        Record(watchStart: start, runs: runs, lastObservedRun: lastObservedRun, lastObservation: observedAt, lastRunNotBefore: lastRunNotBefore)
    }
}
