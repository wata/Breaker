import Foundation
import Observation

/**
 networkQuality による速度計測を、設定の間隔で自動に・利用者の操作で手動に走らせる。
 1回で約300MB 通信するので、従量制の回線やスリープ明けの不安定な間は自動では測らない
 */
@MainActor
@Observable
final class SpeedTestScheduler {
    /// 自動計測を見送るかどうかの判定材料。接続の状態と最新の接続チェックから作る
    struct Conditions: Sendable {
        var isOnline: Bool
        /// テザリングなど従量制の回線
        var isExpensive: Bool
        /// 低データモード
        var isConstrained: Bool
    }

    /// 最後の計測結果（JSON）を UserDefaults に入れておくキー
    static let lastRecordKey = "lastSpeedTestRecord"
    /// 成功した計測の履歴（JSON）を UserDefaults に入れておくキー。詳細の速度の推移のグラフに使う
    static let historyKey = "speedTestHistory"
    /// 履歴を残す期間。グラフは直近7日だけを描くが、間隔を短くしても UserDefaults が膨らみすぎない範囲で余裕を持たせる
    static let historyRetention: TimeInterval = 30 * 24 * 60 * 60
    /// スリープ明けはネットワークがつながり直す途中で、測っても遅い値になりやすい
    static let postWakeQuietPeriod: TimeInterval = 90

    private(set) var lastRecord: SpeedTestRecord?
    private(set) var isMeasuring = false
    /// 成功した計測だけを古い順に持つ。失敗した計測は速度が無く、グラフに載せられない
    private(set) var history: [SpeedTestRecord]

    /// 推移のグラフに描く期間。履歴はこれより長く持つ（`historyRetention`）
    static let chartPeriod: TimeInterval = 7 * 24 * 60 * 60

    /// 推移のグラフに描く、直近の成功した計測。描くたびに絞り込まずに済むよう、ここで1回だけ絞る
    func recentHistory(now: Date) -> [SpeedTestRecord] {
        let startDate = now.addingTimeInterval(-Self.chartPeriod)
        return history.filter { $0.date >= startDate && $0.speed != nil }
    }

    /// `NetworkSource` は MainActor の外で測るので、その時点の状態を値で渡す
    var snapshot: SpeedTestSnapshot {
        SpeedTestSnapshot(lastRecord: lastRecord, isMeasuring: isMeasuring)
    }

    @ObservationIgnored private let speedTester: any SpeedTesting
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let lastWakeDate: @Sendable () -> Date?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let conditions: @Sendable () async -> Conditions?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let onFinish: @MainActor () async -> Void
    @ObservationIgnored private let checkInterval: Duration
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var measurementTask: Task<Void, Never>?

    init(
        speedTester: any SpeedTesting = NetworkQuality(),
        conditions: @escaping @Sendable () async -> Conditions?,
        defaults: UserDefaults = .standard,
        checkInterval: Duration = .seconds(60),
        now: @escaping @Sendable () -> Date = { Date() },
        lastWakeDate: @escaping @Sendable () -> Date? = { WakeMonitor.shared.lastWakeDate },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onFinish: @escaping @MainActor () async -> Void = {}
    ) {
        self.speedTester = speedTester
        self.conditions = conditions
        self.defaults = defaults
        self.checkInterval = checkInterval
        self.now = now
        self.lastWakeDate = lastWakeDate
        self.sleep = sleep
        self.onFinish = onFinish
        let lastRecord = defaults.data(forKey: Self.lastRecordKey).flatMap { try? JSONDecoder().decode(SpeedTestRecord.self, from: $0) }
        self.lastRecord = lastRecord
        // 履歴を持つ前の版から上げたときは、前回の成功を最初の1件にして、次の計測からすぐ推移を描けるようにする
        history = defaults.data(forKey: Self.historyKey).flatMap { try? JSONDecoder().decode([SpeedTestRecord].self, from: $0) }
            ?? [lastRecord].compactMap { $0 }.filter { $0.speed != nil }
    }

    /**
     次の計測まで長く眠らず、短い間隔で期限が来たかだけを見る。
     眠っている間も時計は進むので、スリープをまたいでも期限の判定がずれない
     */
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await measureIfDue()
                try? await sleep(checkInterval)
            }
        }
    }

    /// アプリの終了時に呼ぶ。計測をキャンセルすると networkQuality も止まる
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        measurementTask?.cancel()
    }

    /**
     手動の計測。従量制の回線や低データモードでも利用者が求めたなら測るが、オフラインでは失敗が分かりきっているので測らない。
     まだ接続チェックが無ければ、つながっているとみなして測る
     */
    func measureNow() async {
        guard measurementTask == nil else { return }
        let isOnline = await conditions()?.isOnline ?? true
        // 判定材料を待っている間に自動の計測が始まっていたら重ねない
        guard
            isOnline,
            measurementTask == nil
        else {
            return
        }
        await measure()
    }

    /// ループの1回分。間隔の設定は毎回読み、設定を変えたら次の判定から効かせる
    func measureIfDue() async {
        let date = now()
        guard
            measurementTask == nil,
            let interval = SpeedTestInterval.selected(in: defaults).duration,
            isDue(at: date, interval: interval),
            !isWithinPostWakeQuietPeriod(at: date)
        else {
            return
        }
        // 起動直後でまだ接続チェックが無いと、従量制の回線かどうかが分からないので次の判定まで待つ
        guard
            let conditions = await conditions(),
            conditions.isOnline,
            !conditions.isExpensive,
            !conditions.isConstrained
        else {
            return
        }
        // 判定材料を待っている間に手動の計測が始まっていたら重ねない
        guard measurementTask == nil else { return }
        await measure()
    }

    private func isDue(at date: Date, interval: Duration) -> Bool {
        if let lastRecord {
            return date.timeIntervalSince(lastRecord.date) >= TimeInterval(interval.components.seconds)
        } else {
            return true
        }
    }

    private func isWithinPostWakeQuietPeriod(at date: Date) -> Bool {
        if let wakeDate = lastWakeDate() {
            return date.timeIntervalSince(wakeDate) < Self.postWakeQuietPeriod
        } else {
            return false
        }
    }

    /**
     計測は1つだけにし、stop から止められるよう Task で持つ。キャンセルされたら結果を残さず、更新も呼ばない。
     一覧の取り直しは計測中を外してから呼ぶ。計測中のままだと、取り直しの判定が計測のせいとしてロスや遅延を見送ってしまう
     */
    private func measure() async {
        isMeasuring = true
        let task = Task {
            let record = try? await speedTester.measure()
            measurementTask = nil
            isMeasuring = false
            guard let record else { return }
            lastRecord = record
            defaults.set(try? JSONEncoder().encode(record), forKey: Self.lastRecordKey)
            appendToHistory(record)
            await onFinish()
        }
        measurementTask = task
        await task.value
    }

    /// 保持期間は計測の時刻から数える。時計を注入したテストでも同じ基準で古いものを捨てられる
    private func appendToHistory(_ record: SpeedTestRecord) {
        guard record.speed != nil else { return }
        let oldestDate = record.date.addingTimeInterval(-Self.historyRetention)
        history = (history + [record]).filter { $0.date >= oldestDate }
        defaults.set(try? JSONEncoder().encode(history), forKey: Self.historyKey)
    }
}

extension SpeedTestScheduler.Conditions {
    /// まだ一度もチェックしていない起動直後は判定材料が無いので nil
    init?(latestCheck: NetworkCheckHistory.Check?) {
        guard let latestCheck else { return nil }
        self.init(
            isOnline: latestCheck.health.isOnline(finding: latestCheck.finding),
            isExpensive: latestCheck.health.isExpensive,
            isConstrained: latestCheck.health.isConstrained
        )
    }
}
