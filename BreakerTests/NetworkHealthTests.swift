import Foundation
import Testing
@testable import Breaker

struct NetworkHealthTests {
    /// 説明の欄はネットワーク項目には出さず、自動化の項目には出す
    @Test func onlyAutomationsAcceptNote() {
        #expect(!MonitoredItem.sampleNetwork.acceptsNote)
        #expect(MonitoredItem.samples.contains { $0.networkHealth == nil && $0.acceptsNote })
    }

    /// 遅延・ロス・Wi-Fi の弱さは色で見せるだけで、通知・Dock バッジに数えるのはつながらない失敗だけ
    @Test func onlyFailureIsReportedAbnormal() {
        #expect(!Self.item(.ok).isReportedAbnormal)
        #expect(!Self.item(.warning(reason: "High latency")).isReportedAbnormal)
        #expect(Self.item(.failed(reason: "No connection")).isReportedAbnormal)
    }

    @Test func warningIsNotNotifiedButFailureIs() {
        let ok = Self.item(.ok)
        let warning = Self.item(.warning(reason: "High latency"))
        let failed = Self.item(.failed(reason: "No connection"))
        #expect(AbnormalAlert.alerts(from: nil, to: [warning]).isEmpty)
        #expect(AbnormalAlert.alerts(from: [ok], to: [warning]).isEmpty)
        #expect(AbnormalAlert.alerts(from: [ok], to: [failed]) == [.item(failed)])
        #expect(AbnormalAlert.alerts(from: [warning], to: [failed]) == [.item(failed)])
        #expect(AbnormalAlert.alerts(from: [failed], to: [warning]).isEmpty)
    }

    @Test func networkIsItsOwnKind() {
        let item = Self.item(.ok)
        #expect(item.kind == .network)
        #expect(item.id == "network:network")
        #expect(item.isHomeItem)
        #expect(item.controlActions.isEmpty)
        // 正常でも遅さなどを AI に聞けるよう、プロンプトはいつでもコピーできる
        #expect(item.promptAction?.isEnabled == true)
        #expect(item.recoveryAction == nil)
        #expect(item.fileActions().isEmpty)
    }

    @Test func titleHasJapaneseTranslation() {
        #expect(String(localized: "Network", language: Locale(identifier: "ja_JP")) == "ネットワーク")
    }

    /// 前回の計測は UserDefaults に JSON で残すので、成功も失敗もそのまま戻る
    @Test func speedTestRecordRoundTripsThroughJSON() throws {
        let records = [
            SpeedTestRecord(
                date: Date(timeIntervalSince1970: 1_000_000),
                outcome: .succeeded(.init(
                    downloadBitsPerSecond: 500_000_000,
                    uploadBitsPerSecond: 50_000_000,
                    responsiveness: 1200,
                    baseRoundTripMilliseconds: 12.5
                ))
            ),
            SpeedTestRecord(date: Date(timeIntervalSince1970: 2_000_000), outcome: .failed(reason: "Timed out")),
        ]
        let data = try JSONEncoder().encode(records)
        #expect(try JSONDecoder().decode([SpeedTestRecord].self, from: data) == records)
    }

    private static func item(_ status: ItemStatus) -> MonitoredItem {
        MonitoredItem(
            key: "network",
            name: "Network",
            status: status,
            detail: .network(NetworkHealth(
                pathStatus: .satisfied,
                interface: .wifi,
                isExpensive: false,
                isConstrained: false,
                routerAddress: "192.168.1.1",
                dnsServers: ["192.168.1.1"],
                routerPing: nil,
                internetPing: nil,
                dnsLookup: nil,
                internetAccess: nil,
                wifi: nil,
                lastSpeedTest: nil,
                isTestingSpeed: false
            ))
        )
    }
}
