import Foundation
import Observation

/**
 膨らみやすい場所の走査を、間隔を空けて自動で・利用者の操作で手動で走らせる。
 走査は数分かかり Mac に負荷もかけるので、空きのチェック（1分ごと）とは分け、速度の計測と同じくウインドウを閉じても続ける
 */
@MainActor
@Observable
final class StorageScanScheduler {
    /// 最後の走査結果（JSON）を UserDefaults に入れておくキー
    static let lastScanKey = "lastStorageScan"
    /// 自動で走査する間隔。膨らむのは日単位なので、1日に数回で足りる
    static let interval: TimeInterval = 6 * 60 * 60

    private(set) var lastScan: StorageScan?
    private(set) var isScanning = false

    @ObservationIgnored private let diskUsage: any StorageScanning
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let checkInterval: Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let onFinish: @MainActor () async -> Void
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    /// 走査の結果は AI に渡すプロンプトの材料として項目にも載せるので、終わったら `onFinish` で一覧を取り直す
    init(
        diskUsage: any StorageScanning = DiskUsage(),
        defaults: UserDefaults = .standard,
        checkInterval: Duration = .seconds(60),
        now: @escaping @Sendable () -> Date = { Date() },
        onFinish: @escaping @MainActor () async -> Void = {}
    ) {
        self.diskUsage = diskUsage
        self.defaults = defaults
        self.checkInterval = checkInterval
        self.now = now
        self.onFinish = onFinish
        lastScan = defaults.data(forKey: Self.lastScanKey).flatMap { try? JSONDecoder().decode(StorageScan.self, from: $0) }
    }

    /// 速度の計測と同じく、短い間隔で期限が来たかだけを見る。スリープをまたいでも期限の判定がずれない
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await scanIfDue()
                try? await Task.sleep(for: checkInterval)
            }
        }
    }

    /// アプリの終了時に呼ぶ。キャンセルすると走っている du も止まる
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        scanTask?.cancel()
    }

    func scanNow() async {
        guard scanTask == nil else { return }
        await scan()
    }

    func scanIfDue() async {
        let isDue = lastScan.map { now().timeIntervalSince($0.date) >= Self.interval } ?? true
        guard
            isDue,
            scanTask == nil
        else {
            return
        }
        await scan()
    }

    /// キャンセルされたら結果を残さない。途中で止めた du の合計は小さく出て、次の走査で「増えた」と見誤るため
    private func scan() async {
        isScanning = true
        let previous = lastScan
        let task = Task {
            let scan = await diskUsage.scan(previous: previous)
            scanTask = nil
            isScanning = false
            guard !Task.isCancelled else { return }
            lastScan = scan
            defaults.set(try? JSONEncoder().encode(scan), forKey: Self.lastScanKey)
            await onFinish()
        }
        scanTask = task
        await task.value
    }
}
