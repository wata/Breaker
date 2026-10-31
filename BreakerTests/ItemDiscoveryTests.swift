import Foundation
import Testing
@testable import Breaker

struct ItemDiscoveryTests {
    @Test func sortsByKindThenNameAndKeepsOtherSourcesOnFailure() async {
        let discovery = ItemDiscovery(sources: [
            StubSource(kind: .monitoredApp, result: .success([app("b"), app("A")])),
            StubSource(kind: .folderAction, result: .failure(FolderActionError(status: 1, message: "-1743"))),
            StubSource(kind: .launchdJob, result: .success([job("z.job"), job("a.job")])),
        ])
        let items = await discovery.items()
        #expect(items.map(\.name) == ["a.job", "z.job", "Can't Get Folder Actions", "A", "b"])

        let failure = items[2]
        #expect(failure.kind == .folderAction)
        #expect(failure.detail == .sourceFailure(.folderAction))
        #expect(failure.status.isAbnormal)
        // サイドバーの行には短い理由だけを出し、エラー文は補足に回す
        #expect(failure.status.reason == "Check failed")
        #expect(failure.status.note == FolderActionError(status: 1, message: "-1743").localizedDescription)
    }

    /**
     節の中は失敗 → 要確認 → 正常・実行中 → 停止・未確認、同じ状態の中は名前順。
     Source が返す順が変わっても、正常と実行中が入れ替わっても、並びは変わらない
     */
    @Test func sortsByStatusWithinKind() async {
        let items = [
            job("ok-b", status: .ok),
            job("stopped", status: .inactive(reason: "Disabled")),
            job("ok-a", status: .running),
            job("warn", status: .warning(reason: "x")),
            job("fail-b", status: .failed(reason: "Exit code 1")),
            job("unknown", status: .unknown(reason: "x")),
            job("fail-a", status: HealthCheck.logErrorStatus("Error: boom")),
            app("app-ok"),
        ]
        let expected = ["fail-a", "fail-b", "warn", "ok-a", "ok-b", "stopped", "unknown", "app-ok"]
        #expect(ItemDiscovery.sorted(items).map(\.name) == expected)
        #expect(ItemDiscovery.sorted(items.reversed()).map(\.name) == expected)
        let discovery = ItemDiscovery(sources: [
            StubSource(kind: .monitoredApp, result: .success([app("app-ok")])),
            StubSource(kind: .launchdJob, result: .success(Array(items.dropLast().shuffled()))),
        ])
        #expect(await discovery.items().map(\.name) == expected)
    }

    /// 実機の検出結果を目で確かめる用。`TEST_RUNNER_BREAKER_LIVE=1 xcodebuild test ...` のときだけ動く
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BREAKER_LIVE"] != nil))
    func printsLiveDiscovery() async {
        let items = await ItemDiscovery().items()
        let lines = items.map { "[\($0.kind.rawValue)] \($0.name) — \($0.status) — \($0.autoDescription ?? "説明なし")" }
        print("BREAKER_LIVE \(items.count) items\n" + lines.joined(separator: "\n"))
        #expect(!items.isEmpty)
    }

    private func app(_ name: String) -> MonitoredItem {
        MonitoredItem(
            key: name,
            name: name,
            status: .running,
            detail: .monitoredApp(.init(bundleID: "com.example.\(name)", appURL: URL(filePath: "/Applications/\(name).app"), isRunning: true))
        )
    }

    private func job(_ label: String, status: ItemStatus = .ok) -> MonitoredItem {
        let detail = MonitoredItem.LaunchdJob(
            label: label,
            origin: .userAgent,
            plistURL: URL(filePath: "/tmp/\(label).plist"),
            isDisabledFile: false,
            isDisabledLabel: false,
            isHomeJob: true,
            programArguments: [],
            schedule: Schedule(),
            standardOutPath: nil,
            standardErrorPath: nil,
            service: nil,
            lastRun: nil
        )
        return MonitoredItem(key: label, name: label, status: status, detail: .launchdJob(detail))
    }
}

private struct StubSource: ItemSource {
    let kind: MonitoredItem.Kind
    let result: Result<[MonitoredItem], any Error>

    func items() async throws -> [MonitoredItem] {
        try result.get()
    }
}
