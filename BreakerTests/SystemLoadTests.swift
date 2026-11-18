import Foundation
import Testing
@testable import Breaker

struct SystemLoadTests {
    /// `ps -Ao pcpu=,comm=` の実際の出力の形。パスに空白を含む行と、パスを持たないプロセスがある
    @Test func parsesProcessList() {
        let text = """
         90.4 kernel_task
         61.2 /Applications/Xcode-27.2.0.app/Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/SWBBuildService.bundle/Contents/MacOS/SWBBuildService
          7.9 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)
          broken
        """
        let processes = ProcessList.parse(text)
        #expect(processes.count == 3)
        #expect(processes[0] == ProcessUsage(cpuPercent: 90.4, executable: "kernel_task"))
        #expect(processes[2].executable.hasSuffix("Google Chrome Helper (Renderer)"))
    }

    /// アプリの中の補助プロセスは一番外側のアプリにまとめ、% は足し合わせる（1コア＝100%）
    @Test func groupsProcessesByOutermostApp() {
        let processes = [
            ProcessUsage(cpuPercent: 120, executable: "/Applications/Xcode-27.2.0.app/Contents/Developer/usr/bin/swift-frontend"),
            ProcessUsage(cpuPercent: 60, executable: "/Applications/Xcode-27.2.0.app/Contents/SharedFrameworks/X.framework/Helper.app/Contents/MacOS/Helper"),
            ProcessUsage(cpuPercent: 50, executable: "/usr/sbin/coreaudiod"),
            ProcessUsage(cpuPercent: 10, executable: "kernel_task"),
        ]
        let consumers = SystemLoad.Consumer.consumers(from: processes) { $0.contains("Xcode") ? "Xcode" : nil }
        #expect(consumers.map(\.name) == ["Xcode", "coreaudiod", "kernel_task"])
        #expect(consumers[0].bundlePath == "/Applications/Xcode-27.2.0.app")
        #expect(consumers[0].cpuPercent == 180)
    }

    /// 同じ表示名のアプリ（Xcode の2つの版）は1つにまとめる。記録と判定は名前で引くので、分かれると片方が漏れる
    @Test func mergesAppsWithTheSameName() {
        let processes = [
            ProcessUsage(cpuPercent: 30, executable: "/Applications/Xcode-27.2.0.app/Contents/MacOS/Xcode"),
            ProcessUsage(cpuPercent: 20, executable: "/Applications/Xcode-27.1.0.app/Contents/MacOS/Xcode"),
        ]
        let consumers = SystemLoad.Consumer.consumers(from: processes) { _ in "Xcode" }
        #expect(consumers.map(\.name) == ["Xcode"])
        #expect(consumers[0].cpuPercent == 50)
    }

    /// 表示名が読めないアプリは .app を除いたファイル名にする
    @Test func fallsBackToBundleFileName() {
        let processes = [ProcessUsage(cpuPercent: 10, executable: "/Applications/HomeReel.app/Contents/MacOS/HomeReel")]
        let consumers = SystemLoad.Consumer.consumers(from: processes) { _ in nil }
        #expect(consumers.map(\.name) == ["HomeReel"])
    }

    // MARK: - 判定

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 1分ごとの記録を、今から `minutes` 分さかのぼって作る
    private static func history(minutes: Int, share: (Int) -> Double) -> [LoadSample] {
        (0..<minutes).reversed().map { minutesAgo in
            LoadSample(
                date: now.addingTimeInterval(-Double(minutesAgo) * 60),
                cpuPercent: share(minutesAgo),
                consumers: [LoadSample.Consumer(name: "Reel", cpuPercent: share(minutesAgo))]
            )
        }
    }

    private static func load(history: [LoadSample], thermalState: SystemLoad.ThermalState = .nominal, memoryPressure: SystemLoad.MemoryPressure = .normal) -> SystemLoad {
        SystemLoad(
            cpuPercent: history.last?.cpuPercent ?? 0,
            coreCount: 10,
            loadAverage: 1,
            thermalState: thermalState,
            memoryPressure: memoryPressure,
            consumers: [],
            history: history
        )
    }

    /// 1コアの半分（50%）以上を10分続けて使えば、使い続けているとみなす
    @Test func sustainedConsumer() {
        let history = Self.history(minutes: 30) { _ in 60 }
        #expect(LoadCheck.finding(in: Self.load(history: history), now: Self.now) == .sustainedConsumer(name: "Reel"))
    }

    /// 数分のビルドのような短い山では鳴らさない
    @Test func shortBurstIsIgnored() {
        let history = Self.history(minutes: 30) { $0 < 3 ? 900 : 10 }
        #expect(LoadCheck.finding(in: Self.load(history: history), now: Self.now) == nil)
    }

    /// 起動直後で記録が少ないうちは決めない
    @Test func needsEnoughSamples() {
        let history = Self.history(minutes: 5) { _ in 500 }
        #expect(LoadCheck.finding(in: Self.load(history: history), now: Self.now) == nil)
    }

    /// 上下するアプリも、平均が基準を超えていれば使い続けている
    @Test func fluctuatingConsumerUsesAverage() {
        let history = Self.history(minutes: 10) { $0.isMultiple(of: 2) ? 80 : 30 }
        #expect(LoadCheck.finding(in: Self.load(history: history), now: Self.now) == .sustainedConsumer(name: "Reel"))
    }

    /// 熱はアプリより先に言う。熱で絞られているとほかの値も悪く見える
    @Test func thermalComesFirst() {
        let history = Self.history(minutes: 30) { _ in 60 }
        #expect(LoadCheck.finding(in: Self.load(history: history, thermalState: .serious), now: Self.now) == .thermalThrottling)
        #expect(LoadCheck.finding(in: Self.load(history: [], memoryPressure: .critical), now: Self.now) == .memoryShortage)
    }

    /// いつから: 基準の半分を下回った記録の次から。上下しても1回だけの谷では途切れない
    @Test func sinceDate() {
        let history = Self.history(minutes: 60) { minutesAgo in
            switch minutesAgo {
            case ..<20: 60
            case 20: 30
            case 21..<40: 60
            default: 1
            }
        }
        #expect(LoadCheck.sinceDate(of: "Reel", in: history) == Self.now.addingTimeInterval(-39 * 60))
    }

    /// 理由に数値を入れない。数値が変わるたびに状態が変わって通知が出てしまう
    @Test func reasonIsStable() {
        let first = Self.history(minutes: 30) { _ in 60 }
        let second = Self.history(minutes: 30) { _ in 90 }
        #expect(LoadCheck.finding(in: Self.load(history: first), now: Self.now)?.status == LoadCheck.finding(in: Self.load(history: second), now: Self.now)?.status)
    }

    // MARK: - 記録

    /// 間を置かずに呼ばれたら最後の1件を置き換え、24時間より古い記録と上位より下のアプリは捨てる。起動し直しても残る
    @Test func historyKeepsOneSamplePerMinute() async throws {
        let directory = try TemporaryDirectory()
        let fileURL = directory.url.appending(path: "Breaker/load-history.json")
        let history = LoadHistory(fileURL: fileURL)
        let consumers = (0..<8).map { LoadSample.Consumer(name: "App \($0)", cpuPercent: 0.01) }
        _ = await history.record(LoadSample(date: Self.now.addingTimeInterval(-25 * 3600), cpuPercent: 0.1, consumers: []))
        _ = await history.record(LoadSample(date: Self.now.addingTimeInterval(-60), cpuPercent: 0.2, consumers: []))
        _ = await history.record(LoadSample(date: Self.now.addingTimeInterval(-50), cpuPercent: 0.3, consumers: []))
        let samples = await history.record(LoadSample(date: Self.now, cpuPercent: 0.4, consumers: consumers))
        #expect(samples.map(\.cpuPercent) == [0.3, 0.4])
        #expect(samples.last?.consumers.count == LoadHistory.consumerLimit)

        // ファイルに書くのは `saveInterval` ごとに間引くので、最後に書いた時点（0.2 の記録）までが残っている
        let reopened = LoadHistory(fileURL: fileURL)
        let restored = await reopened.record(LoadSample(date: Self.now.addingTimeInterval(60), cpuPercent: 0.5, consumers: []))
        #expect(restored.map(\.cpuPercent) == [0.2, 0.5])
        _ = await reopened.record(LoadSample(date: Self.now.addingTimeInterval(LoadHistory.saveInterval + 60), cpuPercent: 0.6, consumers: []))
        let saved = await LoadHistory(fileURL: fileURL).record(LoadSample(date: Self.now.addingTimeInterval(LoadHistory.saveInterval + 120), cpuPercent: 0.7, consumers: []))
        #expect(saved.map(\.cpuPercent) == [0.2, 0.5, 0.6, 0.7])
    }

    // MARK: - 書式

    @Test func summary() {
        let load = SystemLoad(
            cpuPercent: 420,
            coreCount: 10,
            loadAverage: 12.34,
            thermalState: .nominal,
            memoryPressure: .normal,
            consumers: [SystemLoad.Consumer(name: "Xcode", bundlePath: nil, cpuPercent: 200)],
            history: []
        )
        let english = Locale(identifier: "en_US")
        #expect(load.summary(locale: english) == "CPU 420% · Xcode")
    }
}
