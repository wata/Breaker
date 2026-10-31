import Foundation
import Testing
@testable import Breaker

/// 検出・通知・Dock バッジはすべてスタブで受け、実システムには触れない
@MainActor
struct AppModelMonitoringTests {
    /// 取得中に届いた依頼は捨てずに、何件届いても今の取得の後に1回だけ取り直し、呼んだ側はその結果まで待つ
    @Test func refreshDuringRefreshRunsExactlyOneFollowUp() async {
        let discover = GatedDiscover()
        let appModel = AppModel { await discover.next() }
        let stale = [MonitoredItem.samples[0]]
        let fresh = [MonitoredItem.samples[2]]

        let first = Task { await appModel.refresh() }
        await discover.waitForPendingCall()
        #expect(appModel.isRefreshing)
        let second = Task { await appModel.refresh() }
        let third = Task { await appModel.refresh() }
        for _ in 0..<10 {
            await Task.yield()
        }
        await discover.resume(with: stale)

        await discover.waitForPendingCall()
        await discover.resume(with: fresh)
        await second.value
        #expect(appModel.items == fresh)
        await first.value
        await third.value

        #expect(await discover.callCount == 2)
        #expect(!appModel.isRefreshing)

        // 取得が終わった後の依頼は、追いかけの取得ではなく新しい取得になる
        let fourth = Task { await appModel.refresh() }
        await discover.waitForPendingCall()
        await discover.resume(with: stale)
        await fourth.value
        #expect(await discover.callCount == 3)
        #expect(appModel.items == stale)
    }

    @Test func monitoringReportsTransitionsAndBadge() async {
        let source = ItemsSource([Self.item("a", .ok), Self.item("b", .failed(reason: "Exit code 1")), Self.item("c", .warning(reason: "Not loaded"))])
        let appModel = AppModel { await source.items }
        let reporter = RecordingReporter()

        appModel.startMonitoring(reporter: reporter, interval: .seconds(3600))
        await appModel.refresh()
        #expect(reporter.alerts == [.summary([Self.item("b", .failed(reason: "Exit code 1")), Self.item("c", .warning(reason: "Not loaded"))])])
        #expect(reporter.badges.last == 2)
        #expect(appModel.abnormalCount == 2)

        source.items = [Self.item("a", .failed(reason: "Exit code 2")), Self.item("b", .ok), Self.item("c", .warning(reason: "Not loaded"))]
        await appModel.refresh()
        #expect(reporter.alerts.dropFirst() == [.item(Self.item("a", .failed(reason: "Exit code 2")))])
        #expect(reporter.badges.last == 2)

        // 異常から戻ったときは通知せず、バッジだけ消す
        source.items = [Self.item("a", .ok), Self.item("b", .ok), Self.item("c", .running)]
        await appModel.refresh()
        #expect(reporter.alerts.count == 2)
        #expect(reporter.badges.last == 0)
    }

    @Test func refreshWithoutMonitoringReportsNothing() async {
        let appModel = AppModel { MonitoredItem.samples }
        await appModel.refresh()
        #expect(appModel.abnormalCount == MonitoredItem.samples.count(where: \.isReportedAbnormal))
        #expect(appModel.abnormalCount > 0)
        // サンプルにはホームのジョブ以外の失敗があり、それは数えない
        #expect(appModel.abnormalCount < MonitoredItem.samples.count { $0.status.isAbnormal })
    }

    /// ホームのジョブ以外が失敗しても、通知も Dock バッジも出さない
    @Test func monitoringIgnoresNonHomeJobs() async {
        let system = MonitoredItem.LaunchdJob.sample("com.example.updater", schedule: Schedule(), isHomeJob: false)
        let failed = MonitoredItem(key: system.label, name: system.label, status: .failed(reason: "Exit code 1"), detail: .launchdJob(system))
        let source = ItemsSource([Self.item("a", .ok), failed])
        let appModel = AppModel { await source.items }
        let reporter = RecordingReporter()

        appModel.startMonitoring(reporter: reporter, interval: .seconds(3600))
        await appModel.refresh()
        #expect(reporter.alerts.isEmpty)
        #expect(reporter.badges.last == 0)
        #expect(appModel.abnormalCount == 0)
    }

    /// 一覧の表示範囲を「すべて」に広げても、通知とバッジはホームのジョブと launchd 以外だけ
    @Test func monitoringIgnoresLaunchdScope() async throws {
        let defaults = try IsolatedDefaults()
        let items = AppModelTests.scopedItems(status: .failed(reason: "Exit code 1"))
        let appModel = AppModel(defaults: defaults.userDefaults) { items }
        appModel.launchdScope = .all
        let reporter = RecordingReporter()

        appModel.startMonitoring(reporter: reporter, interval: .seconds(3600))
        await appModel.refresh()
        #expect(reporter.badges.last == 2)
        #expect(reporter.alerts == AbnormalAlert.alerts(from: nil, to: items.filter(\.isHomeItem)))
    }

    @Test func revealSelectsItemOrFiltersForSummary() throws {
        let defaults = try IsolatedDefaults()
        let appModel = AppModel(items: MonitoredItem.samples, defaults: defaults.userDefaults)
        let failed = MonitoredItem.samples[2]

        appModel.reveal(itemID: failed.id)
        #expect(appModel.selectedItem == failed)
        #expect(!appModel.showsAbnormalOnly)

        appModel.reveal(itemID: nil)
        #expect(appModel.showsAbnormalOnly)
    }

    private static func item(_ key: String, _ status: ItemStatus) -> MonitoredItem {
        MonitoredItem(
            key: key,
            name: key,
            status: status,
            detail: .swiftBarPlugin(.init(fileURL: URL(filePath: "/tmp/\(key).sh"), refreshInterval: nil))
        )
    }
}

/// 呼ばれた検出をテストが結果を渡すまで止めておく
private actor GatedDiscover {
    private(set) var callCount = 0
    private var pending: CheckedContinuation<[MonitoredItem], Never>?

    func next() async -> [MonitoredItem] {
        callCount += 1
        return await withCheckedContinuation { pending = $0 }
    }

    func waitForPendingCall() async {
        while pending == nil {
            await Task.yield()
        }
    }

    func resume(with items: [MonitoredItem]) {
        pending?.resume(returning: items)
        pending = nil
    }
}

@MainActor
private final class ItemsSource {
    var items: [MonitoredItem]

    init(_ items: [MonitoredItem]) {
        self.items = items
    }
}

@MainActor
private final class RecordingReporter: AbnormalReporting {
    private(set) var alerts = [AbnormalAlert]()
    private(set) var badges = [Int]()

    func post(_ alerts: [AbnormalAlert]) async {
        self.alerts += alerts
    }

    func showBadge(count: Int) {
        badges.append(count)
    }
}
