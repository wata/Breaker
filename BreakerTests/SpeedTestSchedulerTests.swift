import Foundation
import Testing
@testable import Breaker

@MainActor
struct SpeedTestSchedulerTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let online = SpeedTestScheduler.Conditions(isOnline: true, isExpensive: false, isConstrained: false)

    @Test func measuresWhenNoPreviousRecord() async throws {
        let defaults = try IsolatedDefaults()
        let speedTester = StubSpeedTester()

        await makeScheduler(speedTester: speedTester, defaults: defaults.userDefaults).measureIfDue()

        #expect(speedTester.callCount == 1)
    }

    /// 既定の1時間。期限は前回の計測の時刻から数える
    @Test func measuresOnlyAfterIntervalHasPassed() async throws {
        let defaults = try IsolatedDefaults()
        save(record(date: start), in: defaults.userDefaults)
        let clock = Clock(start.addingTimeInterval(59 * 60))
        let speedTester = StubSpeedTester()
        let scheduler = makeScheduler(speedTester: speedTester, defaults: defaults.userDefaults, clock: clock)

        await scheduler.measureIfDue()
        #expect(speedTester.callCount == 0)

        clock.date = start.addingTimeInterval(60 * 60)
        await scheduler.measureIfDue()
        #expect(speedTester.callCount == 1)
    }

    @Test func manualOnlyNeverMeasuresAutomatically() async throws {
        let defaults = try IsolatedDefaults()
        SpeedTestInterval.save(.manual, in: defaults.userDefaults)
        let speedTester = StubSpeedTester()

        await makeScheduler(speedTester: speedTester, defaults: defaults.userDefaults).measureIfDue()

        #expect(speedTester.callCount == 0)
    }

    /// 設定を変えたら、同じインスタンスの次の判定から効く
    @Test func intervalChangeTakesEffectOnNextCheck() async throws {
        let defaults = try IsolatedDefaults()
        save(record(date: start), in: defaults.userDefaults)
        let clock = Clock(start.addingTimeInterval(20 * 60))
        let speedTester = StubSpeedTester()
        let scheduler = makeScheduler(speedTester: speedTester, defaults: defaults.userDefaults, clock: clock)

        await scheduler.measureIfDue()
        #expect(speedTester.callCount == 0)

        SpeedTestInterval.save(.fifteenMinutes, in: defaults.userDefaults)
        clock.date = start.addingTimeInterval(21 * 60)
        await scheduler.measureIfDue()
        #expect(speedTester.callCount == 1)
    }

    @Test(arguments: [
        SpeedTestScheduler.Conditions(isOnline: false, isExpensive: false, isConstrained: false),
        SpeedTestScheduler.Conditions(isOnline: true, isExpensive: true, isConstrained: false),
        SpeedTestScheduler.Conditions(isOnline: true, isExpensive: false, isConstrained: true),
    ])
    func skipsAutomaticMeasurementOnUnsuitableNetwork(conditions: SpeedTestScheduler.Conditions) async throws {
        let defaults = try IsolatedDefaults()
        let speedTester = StubSpeedTester()

        await makeScheduler(speedTester: speedTester, defaults: defaults.userDefaults, conditions: conditions).measureIfDue()

        #expect(speedTester.callCount == 0)
    }

    /// スリープから明けて90秒は測らない
    @Test func skipsAutomaticMeasurementRightAfterWake() async throws {
        let defaults = try IsolatedDefaults()
        let clock = Clock(start)
        let speedTester = StubSpeedTester()
        let scheduler = makeScheduler(speedTester: speedTester, defaults: defaults.userDefaults, clock: clock, wakeDate: start)

        clock.date = start.addingTimeInterval(60)
        await scheduler.measureIfDue()
        #expect(speedTester.callCount == 0)

        clock.date = start.addingTimeInterval(90)
        await scheduler.measureIfDue()
        #expect(speedTester.callCount == 1)
    }

    /// 起動直後でまだ接続チェックが無いと従量制の回線か分からないので、自動では測らない
    @Test func skipsAutomaticMeasurementBeforeFirstCheck() async throws {
        let defaults = try IsolatedDefaults()
        let speedTester = StubSpeedTester()

        await makeScheduler(speedTester: speedTester, defaults: defaults.userDefaults, hasCheck: false).measureIfDue()

        #expect(speedTester.callCount == 0)
    }

    /// 手動は利用者が求めたので、まだ接続チェックが無くても測る
    @Test func measureNowMeasuresBeforeFirstCheck() async throws {
        let defaults = try IsolatedDefaults()
        let speedTester = StubSpeedTester()

        await makeScheduler(speedTester: speedTester, defaults: defaults.userDefaults, hasCheck: false).measureNow()

        #expect(speedTester.callCount == 1)
    }

    /// 取り直しの判定が計測のせいとしてロスや遅延を見送らないよう、計測中を外してから一覧を取り直す
    @Test func onFinishSeesMeasurementEnded() async throws {
        let defaults = try IsolatedDefaults()
        var wasMeasuring: Bool?
        var scheduler: SpeedTestScheduler?
        scheduler = makeScheduler(speedTester: StubSpeedTester(), defaults: defaults.userDefaults) {
            wasMeasuring = scheduler?.isMeasuring
        }

        await scheduler?.measureNow()

        #expect(wasMeasuring == false)
    }

    /// 手動は従量制の回線・低データモード・スリープ明けでも測る
    @Test func measureNowIgnoresExpensiveAndConstrainedNetwork() async throws {
        let defaults = try IsolatedDefaults()
        let speedTester = StubSpeedTester()
        let conditions = SpeedTestScheduler.Conditions(isOnline: true, isExpensive: true, isConstrained: true)

        await makeScheduler(speedTester: speedTester, defaults: defaults.userDefaults, conditions: conditions).measureNow()

        #expect(speedTester.callCount == 1)
    }

    @Test func measureNowDoesNothingWhenOffline() async throws {
        let defaults = try IsolatedDefaults()
        let speedTester = StubSpeedTester()
        let conditions = SpeedTestScheduler.Conditions(isOnline: false, isExpensive: false, isConstrained: false)

        await makeScheduler(speedTester: speedTester, defaults: defaults.userDefaults, conditions: conditions).measureNow()

        #expect(speedTester.callCount == 0)
    }

    @Test func measureNowWhileMeasuringIsIgnored() async throws {
        let defaults = try IsolatedDefaults()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let speedTester = StubSpeedTester { [start] in
            for await _ in gate { break }
            return SpeedTestRecord(date: start, outcome: .failed(reason: "stub"))
        }
        let scheduler = makeScheduler(speedTester: speedTester, defaults: defaults.userDefaults)

        let first = Task { await scheduler.measureNow() }
        await speedTester.waitUntilStarted()
        #expect(scheduler.isMeasuring)

        await scheduler.measureNow()
        await scheduler.measureIfDue()
        open.yield()
        await first.value

        #expect(speedTester.callCount == 1)
        #expect(!scheduler.isMeasuring)
    }

    @Test(arguments: [
        SpeedTestRecord.Outcome.succeeded(.init(
            downloadBitsPerSecond: 100_000_000,
            uploadBitsPerSecond: 20_000_000,
            responsiveness: 1200,
            baseRoundTripMilliseconds: 12
        )),
        SpeedTestRecord.Outcome.failed(reason: "networkQuality failed with exit code 1"),
    ])
    func savesRecordAndRestoresItAfterRelaunch(outcome: SpeedTestRecord.Outcome) async throws {
        let defaults = try IsolatedDefaults()
        let expected = SpeedTestRecord(date: start, outcome: outcome)
        let scheduler = makeScheduler(speedTester: StubSpeedTester { expected }, defaults: defaults.userDefaults)

        await scheduler.measureNow()
        #expect(scheduler.lastRecord == expected)

        let relaunched = makeScheduler(speedTester: StubSpeedTester(), defaults: try #require(UserDefaults(suiteName: defaults.suiteName)))
        #expect(relaunched.lastRecord == expected)
    }

    /// 成功した計測だけを履歴に足し、起動し直しても読み戻す
    @Test func appendsSucceededRecordsToHistoryAndRestoresIt() async throws {
        let defaults = try IsolatedDefaults()
        let succeeded = SpeedTestRecord(date: start, outcome: .succeeded(speed))
        let failed = SpeedTestRecord(date: start.addingTimeInterval(60), outcome: .failed(reason: "stub"))
        let results = Results([succeeded, failed])
        let scheduler = makeScheduler(speedTester: StubSpeedTester { results.next() }, defaults: defaults.userDefaults)

        await scheduler.measureNow()
        await scheduler.measureNow()
        #expect(scheduler.history == [succeeded])

        let relaunched = makeScheduler(speedTester: StubSpeedTester(), defaults: try #require(UserDefaults(suiteName: defaults.suiteName)))
        #expect(relaunched.history == [succeeded])
    }

    /// 計測の時刻から30日より前のものは捨てる
    @Test func dropsHistoryOlderThanRetention() async throws {
        let defaults = try IsolatedDefaults()
        let old = SpeedTestRecord(date: start.addingTimeInterval(-SpeedTestScheduler.historyRetention - 1), outcome: .succeeded(speed))
        let boundary = SpeedTestRecord(date: start.addingTimeInterval(-SpeedTestScheduler.historyRetention), outcome: .succeeded(speed))
        defaults.userDefaults.set(try JSONEncoder().encode([old, boundary]), forKey: SpeedTestScheduler.historyKey)
        let latest = SpeedTestRecord(date: start, outcome: .succeeded(speed))
        let scheduler = makeScheduler(speedTester: StubSpeedTester { latest }, defaults: defaults.userDefaults)

        await scheduler.measureNow()

        #expect(scheduler.history == [boundary, latest])
    }

    /// 履歴を持つ前の版から上げたときは、前回の成功を最初の1件にする。失敗なら空から始める
    @Test(arguments: [true, false])
    func seedsHistoryWithLastSucceededRecord(succeeded: Bool) throws {
        let defaults = try IsolatedDefaults()
        let last = SpeedTestRecord(date: start, outcome: succeeded ? .succeeded(speed) : .failed(reason: "stub"))
        save(last, in: defaults.userDefaults)

        let scheduler = makeScheduler(speedTester: StubSpeedTester(), defaults: defaults.userDefaults)

        #expect(scheduler.history == (succeeded ? [last] : []))
    }

    @Test func callsOnFinishAfterSavingRecord() async throws {
        let defaults = try IsolatedDefaults()
        var finishedRecords = [SpeedTestRecord?]()
        var scheduler: SpeedTestScheduler?
        scheduler = makeScheduler(speedTester: StubSpeedTester(), defaults: defaults.userDefaults) {
            finishedRecords.append(scheduler?.lastRecord)
        }

        await scheduler?.measureNow()

        #expect(finishedRecords == [record(date: start)])
    }

    /// アプリの終了時。計測を止め、結果は残さず、一覧の更新も呼ばない
    @Test func stopCancelsMeasurement() async throws {
        let defaults = try IsolatedDefaults()
        let speedTester = StubSpeedTester { [start] in
            try await Task.sleep(for: .seconds(3600))
            return SpeedTestRecord(date: start, outcome: .failed(reason: "stub"))
        }
        var finishCount = 0
        let scheduler = makeScheduler(speedTester: speedTester, defaults: defaults.userDefaults) {
            finishCount += 1
        }

        let measurement = Task { await scheduler.measureNow() }
        await speedTester.waitUntilStarted()
        scheduler.stop()
        await measurement.value

        #expect(speedTester.wasCancelled)
        #expect(scheduler.lastRecord == nil)
        #expect(!scheduler.isMeasuring)
        #expect(finishCount == 0)
        #expect(defaults.userDefaults.data(forKey: SpeedTestScheduler.lastRecordKey) == nil)
    }

    /// start はすぐに1回判定し、以後は注入した間隔で待つ
    @Test func startChecksImmediatelyAndWaitsCheckInterval() async throws {
        let defaults = try IsolatedDefaults()
        let speedTester = StubSpeedTester()
        let sleeps = SleepRecorder()
        let scheduler = SpeedTestScheduler(
            speedTester: speedTester,
            conditions: { [online] in online },
            defaults: defaults.userDefaults,
            checkInterval: .seconds(60),
            now: { [start] in start },
            sleep: sleeps.record
        )

        scheduler.start()
        await sleeps.waitUntilFirstSleep()
        scheduler.stop()

        #expect(speedTester.callCount == 1)
        #expect(sleeps.durations.first == .seconds(60))
    }

    /// NetworkSource が読む状態。計測中は isMeasuring が立ち、終わると結果が入る
    @Test func snapshotFollowsMeasurement() async throws {
        let defaults = try IsolatedDefaults()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let expected = record(date: start)
        let speedTester = StubSpeedTester {
            for await _ in gate { break }
            return expected
        }
        let scheduler = makeScheduler(speedTester: speedTester, defaults: defaults.userDefaults)
        #expect(scheduler.snapshot == .idle)

        let measurement = Task { await scheduler.measureNow() }
        await speedTester.waitUntilStarted()
        #expect(scheduler.snapshot == SpeedTestSnapshot(lastRecord: nil, isMeasuring: true))

        open.yield()
        await measurement.value
        #expect(scheduler.snapshot == SpeedTestSnapshot(lastRecord: expected, isMeasuring: false))
    }

    @Test func conditionsWithoutCheckAreUnknown() {
        #expect(SpeedTestScheduler.Conditions(latestCheck: nil) == nil)
    }

    @Test func conditionsCopyPathOfLatestCheck() throws {
        let check = NetworkCheckHistory.Check(health: Self.health(isExpensive: true, isConstrained: true), finding: nil)
        let conditions = try #require(SpeedTestScheduler.Conditions(latestCheck: check))

        #expect(conditions.isOnline)
        #expect(conditions.isExpensive)
        #expect(conditions.isConstrained)
    }

    /// 揺れ止め前の判定で見るので、接続系の失敗が1回でもあればオフライン扱いにする。接続系でない問題では測る
    @Test(arguments: [
        (NetworkCheck.Finding.offline, false),
        (.routerNotResponding(routerAddress: "192.168.1.1"), false),
        (.internetUnreachable, false),
        (.dnsNotResponding, false),
        (.captivePortal, true),
        (.packetLoss, true),
        (.highLatency, true),
        (.weakWiFiSignal, true),
        (.speedTestFailed(reason: "stub"), true),
    ])
    func conditionsAreOfflineOnConnectionFailure(finding: NetworkCheck.Finding, isOnline: Bool) {
        let check = NetworkCheckHistory.Check(health: Self.health(), finding: finding)

        #expect(SpeedTestScheduler.Conditions(latestCheck: check)?.isOnline == isOnline)
    }

    @Test func conditionsAreOfflineWhenPathIsUnsatisfied() {
        let check = NetworkCheckHistory.Check(health: Self.health(pathStatus: .unsatisfied), finding: nil)

        #expect(SpeedTestScheduler.Conditions(latestCheck: check)?.isOnline == false)
    }

    /// `-BreakerSampleData YES` とプレビューでは、計測せずに前回の結果に見本の値を出す
    @Test func sampleDataShowsSampleRecord() {
        #expect(SpeedTestScheduler.sampleData().lastRecord == SpeedTestRecord.sample)
    }

    private static func health(
        pathStatus: NetworkHealth.PathStatus = .satisfied,
        isExpensive: Bool = false,
        isConstrained: Bool = false
    ) -> NetworkHealth {
        NetworkHealth(
            pathStatus: pathStatus,
            interface: .wifi,
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            routerAddress: "192.168.1.1",
            dnsServers: [],
            routerPing: nil,
            internetPing: nil,
            dnsLookup: nil,
            internetAccess: nil,
            wifi: nil,
            lastSpeedTest: nil,
            isTestingSpeed: false
        )
    }

    private func makeScheduler(
        speedTester: StubSpeedTester,
        defaults: UserDefaults,
        clock: Clock? = nil,
        conditions: SpeedTestScheduler.Conditions? = nil,
        hasCheck: Bool = true,
        wakeDate: Date? = nil,
        onFinish: @escaping @MainActor () async -> Void = {}
    ) -> SpeedTestScheduler {
        let clock = clock ?? Clock(start)
        let conditions = hasCheck ? conditions ?? online : nil
        return SpeedTestScheduler(
            speedTester: speedTester,
            conditions: { conditions },
            defaults: defaults,
            now: { clock.date },
            lastWakeDate: { wakeDate },
            sleep: { _ in },
            onFinish: onFinish
        )
    }

    private let speed = SpeedTestRecord.Speed(
        downloadBitsPerSecond: 100_000_000,
        uploadBitsPerSecond: 20_000_000,
        responsiveness: 1200,
        baseRoundTripMilliseconds: 12
    )

    private func record(date: Date) -> SpeedTestRecord {
        SpeedTestRecord(date: date, outcome: .failed(reason: "stub"))
    }

    private func save(_ record: SpeedTestRecord, in defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(record), forKey: SpeedTestScheduler.lastRecordKey)
    }
}

/// 実際の networkQuality を走らせず（約300MB 通信する）、呼ばれた回数とキャンセルを記録する
private final class StubSpeedTester: SpeedTesting, @unchecked Sendable {
    private let result: @Sendable () async throws -> SpeedTestRecord
    private let lock = NSLock()
    private var recordedCallCount = 0
    private var recordedCancellation = false
    private let (started, startedContinuation) = AsyncStream<Void>.makeStream()

    init(result: @escaping @Sendable () async throws -> SpeedTestRecord = {
        SpeedTestRecord(date: Date(timeIntervalSince1970: 1_800_000_000), outcome: .failed(reason: "stub"))
    }) {
        self.result = result
    }

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    var wasCancelled: Bool {
        lock.withLock { recordedCancellation }
    }

    func waitUntilStarted() async {
        for await _ in started { break }
    }

    func measure() async throws -> SpeedTestRecord {
        lock.withLock { recordedCallCount += 1 }
        startedContinuation.yield()
        do {
            return try await result()
        } catch {
            lock.withLock { recordedCancellation = error is CancellationError }
            throw error
        }
    }
}

/// テストごとに進める時計
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        current = date
    }

    var date: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// 実際には待たず、待とうとした長さを記録する。最初の待ちで止め、ループが空回りしないようにする
private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [Duration]()
    private let (slept, sleptContinuation) = AsyncStream<Void>.makeStream()

    var durations: [Duration] {
        lock.withLock { recorded }
    }

    func waitUntilFirstSleep() async {
        for await _ in slept { break }
    }

    func record(_ duration: Duration) async throws {
        lock.withLock { recorded.append(duration) }
        sleptContinuation.yield()
        try await Task.sleep(for: .seconds(3600))
    }
}

/// 呼ばれるたびに次の結果を返す
private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [SpeedTestRecord]

    init(_ records: [SpeedTestRecord]) {
        remaining = records
    }

    func next() -> SpeedTestRecord {
        lock.withLock { remaining.removeFirst() }
    }
}
