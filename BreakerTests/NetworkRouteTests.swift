import Foundation
import Testing
@testable import Breaker

struct NetworkRouteTests {
    private typealias Stage = ItemDetailView.RouteStage
    private let locale = Locale(identifier: "en_US")

    @Test func healthyNetworkReachesEveryStage() throws {
        let health = try #require(MonitoredItem.sampleNetwork.networkHealth)

        let stages = stages(of: health, status: .ok)

        #expect(stages.map(\.state) == [.reached, .reached, .reached, .reached])
        #expect(stages.map(\.value) == ["Wi-Fi", "3.4 ms", "13 ms", "18 ms"])
    }

    /// オフラインなら Mac が原因で、先はどれも届いていない
    @Test func offlineMarksMacAndCutsTheRest() throws {
        let health = try #require(MonitoredItem.sampleNetworkOffline.networkHealth)
        let status = NetworkCheck.status(of: health)

        let stages = stages(of: health, status: status)

        #expect(stages.map(\.state) == [.cause(status), .unreached, .unreached, .unreached])
        #expect(stages[0].value == "Not connected")
    }

    /// ルーターで切れていれば、DNS がキャッシュで引けても先は届いていないものとして見せる
    @Test func routerFailureCutsInternetAndDNS() {
        let health = Self.health(routerReplies: false, internetAccess: .unreachable(reason: "timed out"), internetReplies: false)
        let status = NetworkCheck.status(of: health)

        let stages = stages(of: health, status: status)

        #expect(stages.map(\.state) == [.reached, .cause(status), .unreached, .unreached])
        #expect(stages[1].value == "No response")
    }

    /// 揺れ止め中（1回目の失敗）は、ヘッダーと同じ要確認の色で目立たせる
    @Test func connectionFailureDuringHysteresisUsesWarning() {
        let health = Self.health(routerReplies: false, internetAccess: .unreachable(reason: "timed out"), internetReplies: false)
        let checking = ItemStatus.warning(reason: "Checking")

        let stages = stages(of: health, status: checking)

        #expect(stages[1].state == .cause(checking))
    }

    /// ルーターが ping に応答しなくても、インターネットに届いていれば通れているので失敗にしない
    @Test func silentRouterIsReachedWhenInternetIsReachable() {
        let health = Self.health(routerReplies: false, internetAccess: .reachable, internetReplies: true)

        let stages = stages(of: health, status: .ok)

        #expect(stages[1].state == .reached)
        #expect(stages[1].value == "No ping reply")
    }

    /// DNS だけが失敗なら、手前の段は届いている
    @Test func dnsFailureMarksOnlyDNS() {
        let health = Self.health(dnsLookup: .failed(reason: "nodename nor servname provided"))
        let status = NetworkCheck.status(of: health)

        let stages = stages(of: health, status: status)

        #expect(stages.map(\.state) == [.reached, .reached, .reached, .cause(status)])
    }

    /// ロスは接続の失敗ではないので、先の DNS は届いたまま
    @Test func packetLossMarksInternetWithoutCuttingDNS() throws {
        let health = try #require(MonitoredItem.sampleNetworkWarning.networkHealth)
        let status = NetworkCheck.status(of: health)

        let stages = stages(of: health, status: status)

        #expect(stages.map(\.state) == [.reached, .reached, .cause(status), .reached])
        #expect(stages[2].value == "20% loss")
    }

    @Test(arguments: [
        (-40, 4),
        (-50, 4),
        (-51, 3),
        (-60, 3),
        (-61, 2),
        (-70, 2),
        (-71, 1),
        (-90, 1),
    ])
    func signalLevel(rssi: Int, level: Int) {
        #expect(Self.wifi(rssi: rssi).signalLevel == level)
    }

    /// 弱いと判定する電波はちょうど1本になり、バーと判定が食い違わない
    @Test(arguments: -100...(-30))
    func weakSignalIsOneBar(rssi: Int) {
        #expect((Self.wifi(rssi: rssi).signalLevel == 1) == NetworkCheck.isWeak(rssi: rssi))
    }

    private func stages(of health: NetworkHealth, status: ItemStatus) -> [Stage] {
        Stage.stages(of: health, cause: .init(finding: NetworkCheck.finding(in: health), status: status), locale: locale)
    }

    private static func health(
        routerReplies: Bool = true,
        internetAccess: NetworkHealth.InternetAccess = .reachable,
        internetReplies: Bool = true,
        dnsLookup: NetworkHealth.DNSLookup = .resolved(milliseconds: 18)
    ) -> NetworkHealth {
        NetworkHealth(
            pathStatus: .satisfied,
            interface: .wiredEthernet,
            isExpensive: false,
            isConstrained: false,
            routerAddress: "192.168.1.1",
            dnsServers: ["192.168.1.1"],
            routerPing: routerReplies
                ? .init(destination: "192.168.1.1", receivedCount: 10, lossRate: 0, averageMilliseconds: 3.4)
                : .init(destination: "192.168.1.1", receivedCount: 0, lossRate: 1, averageMilliseconds: nil),
            internetPing: internetReplies
                ? .init(destination: "1.1.1.1", receivedCount: 10, lossRate: 0, averageMilliseconds: 12.8)
                : .init(destination: "1.1.1.1", receivedCount: 0, lossRate: 1, averageMilliseconds: nil),
            dnsLookup: dnsLookup,
            internetAccess: internetAccess,
            wifi: nil,
            lastSpeedTest: nil,
            isTestingSpeed: false
        )
    }

    private static func wifi(rssi: Int) -> NetworkHealth.WiFiInfo {
        .init(
            interfaceName: "en0",
            ssid: nil,
            rssi: rssi,
            noise: -95,
            channelNumber: 36,
            band: .fiveGigahertz,
            channelWidth: 80,
            phyMode: "802.11ax",
            transmitRate: 864
        )
    }
}
