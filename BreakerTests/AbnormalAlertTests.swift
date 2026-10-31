import Foundation
import Testing
@testable import Breaker

struct AbnormalAlertTests {
    private static let ok = item("a", .ok)
    private static let failed = item("a", .failed(reason: "Exit code 1"))
    private static let otherFailed = item("b", .warning(reason: "Not loaded"))

    @Test func firstCheckSummarizesMultipleAbnormalItems() {
        let alerts = AbnormalAlert.alerts(from: nil, to: [Self.failed, Self.otherFailed, Self.item("c", .running)])
        #expect(alerts == [.summary([Self.failed, Self.otherFailed])])
    }

    @Test func firstCheckWithSingleAbnormalItemNamesIt() {
        #expect(AbnormalAlert.alerts(from: nil, to: [Self.failed, Self.item("c", .ok)]) == [.item(Self.failed)])
    }

    @Test func firstCheckWithoutAbnormalItemsIsSilent() {
        #expect(AbnormalAlert.alerts(from: nil, to: [Self.ok, Self.item("c", .inactive(reason: "Disabled"))]).isEmpty)
    }

    /// 未ロード・スクリプトが無い・ログにエラーは仕事ができていないので失敗として知らせる。理由が変わればもう一度知らせる
    @Test func jobsThatCantWorkAreReportedAsFailures() {
        let loaded = LaunchdServiceInfo(state: "not running", pid: nil, runs: 1, lastExit: .code(0))
        let notLoaded = LaunchAgentSource.status(isDisabledFile: false, isDisabledLabel: false, service: nil, keepAlive: false)
        let missingScript = LaunchAgentSource.status(
            isDisabledFile: false,
            isDisabledLabel: false,
            service: loaded,
            keepAlive: false,
            fileFailure: .failed(reason: "Script not found", note: "~/x.py")
        )
        let logError = LaunchAgentSource.status(isDisabledFile: false, isDisabledLabel: false, service: loaded, keepAlive: false, logError: "Error: boom")
        let items = [Self.item("a", notLoaded), Self.item("b", missingScript), Self.item("c", logError)]
        #expect(items.allSatisfy { $0.status.isFailed && $0.isReportedAbnormal })
        #expect(AbnormalAlert.alerts(from: [Self.item("c", .ok)], to: [items[2]]) == [.item(items[2])])
        let otherLine = Self.item("c", HealthCheck.logErrorStatus("Error: other"))
        #expect(AbnormalAlert.alerts(from: [items[2]], to: [otherLine]) == [.item(otherLine)])
    }

    @Test func okToAbnormalIsReported() {
        #expect(AbnormalAlert.alerts(from: [Self.ok], to: [Self.failed]) == [.item(Self.failed)])
    }

    /// 同じ異常が続いても、60秒ごとに通知し直さない
    @Test func ongoingAbnormalIsNotRepeated() {
        #expect(AbnormalAlert.alerts(from: [Self.failed, Self.otherFailed], to: [Self.failed, Self.otherFailed]).isEmpty)
    }

    @Test func changedReasonIsReported() {
        let changed = Self.item("a", .failed(reason: "Signal 9"))
        #expect(AbnormalAlert.alerts(from: [Self.failed], to: [changed]) == [.item(changed)])
    }

    @Test func failedToWarningIsReported() {
        let warning = Self.item("a", .warning(reason: "Exit code 1"))
        #expect(AbnormalAlert.alerts(from: [Self.failed], to: [warning]) == [.item(warning)])
    }

    @Test func newAbnormalItemIsReported() {
        #expect(AbnormalAlert.alerts(from: [Self.ok], to: [Self.ok, Self.otherFailed]) == [.item(Self.otherFailed)])
    }

    @Test func recoveryIsSilent() {
        #expect(AbnormalAlert.alerts(from: [Self.failed], to: [Self.ok]).isEmpty)
    }

    /// 停止中（inactive）は意図して止めているので異常として数えない
    @Test func inactiveIsNotReported() {
        #expect(AbnormalAlert.alerts(from: [Self.ok], to: [Self.item("a", .inactive(reason: "Disabled"))]).isEmpty)
    }

    /// アプリが入れたジョブ（ホームのジョブ以外）は、異常になっても知らせない
    @Test func nonHomeJobIsNotReported() {
        let system = MonitoredItem(
            key: "com.example.updater",
            name: "com.example.updater",
            status: .failed(reason: "Exit code 1"),
            detail: .launchdJob(.sample("com.example.updater", schedule: Schedule(), isHomeJob: false))
        )
        #expect(AbnormalAlert.alerts(from: nil, to: [system]).isEmpty)
        #expect(AbnormalAlert.alerts(from: nil, to: [system, Self.failed]) == [.item(Self.failed)])
        #expect(AbnormalAlert.alerts(from: [Self.ok], to: [Self.ok, system]).isEmpty)
    }

    /// `/Library` の閲覧のみのジョブは、失敗しても読めなくても知らせない
    @Test func libraryJobIsNotReported() {
        let failed = MonitoredItem(
            key: "/Library/LaunchDaemons/com.example.helper",
            name: "com.example.helper",
            status: .failed(reason: "Exit code 78"),
            detail: .launchdJob(.sample("com.example.helper", schedule: Schedule(), isHomeJob: false, origin: .daemon))
        )
        let unknown = MonitoredItem(
            key: "/Library/LaunchAgents/com.example.agent",
            name: "com.example.agent",
            status: .unknown(reason: "Can't read status"),
            detail: .launchdJob(.sample("com.example.agent", schedule: Schedule(), isHomeJob: false, origin: .systemAgent))
        )
        #expect(AbnormalAlert.alerts(from: [Self.ok], to: [Self.ok, failed, unknown]).isEmpty)
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
