import Foundation
import Testing
@testable import Breaker

struct NetworkCheckTests {
    typealias Finding = NetworkCheck.Finding

    // MARK: - 表の各行

    @Test func healthyNetworkIsOK() {
        #expect(NetworkCheck.finding(in: Self.health()) == nil)
        #expect(NetworkCheck.status(of: Self.health()) == .ok)
    }

    @Test func unsatisfiedPathIsOffline() {
        #expect(NetworkCheck.finding(in: Self.health(pathStatus: .unsatisfied)) == .offline)
    }

    /// VPN のオンデマンドなどは使えばつながるので、オフラインにしない
    @Test func pathRequiringConnectionIsNotOffline() {
        #expect(NetworkCheck.finding(in: Self.health(pathStatus: .requiresConnection)) == nil)
    }

    @Test func silentRouterWithoutInternetIsRouterNotResponding() {
        let health = Self.health(routerPing: Self.ping(received: 0), internetPing: Self.ping(received: 0), internetAccess: .unreachable(reason: "Timed out"))
        #expect(NetworkCheck.finding(in: health) == .routerNotResponding(routerAddress: "192.168.1.1"))
        #expect(NetworkCheck.status(of: health).note == "192.168.1.1")
    }

    /// ルーターのアドレスが無い経路（IPv6 だけ・VPN だけ）は確かめる先が無いので、ルーターのせいにしない
    @Test func missingRouterWithoutInternetIsInternetUnreachable() {
        let health = Self.health(routerAddress: nil, routerPing: nil, internetPing: Self.ping(received: 0), internetAccess: .unreachable(reason: "Timed out"))
        #expect(NetworkCheck.finding(in: health) == .internetUnreachable)
    }

    /// 外部への ICMP を落とすネットワークでも、到達できていればロスとして要確認にしない
    @Test func blockedExternalPingIsIgnoredWhenReachable() {
        let health = Self.health(internetPing: Self.ping(received: 0), internetAccess: .reachable)
        #expect(NetworkCheck.finding(in: health) == nil)
    }

    @Test func respondingRouterWithoutInternetIsInternetUnreachable() {
        let health = Self.health(internetPing: Self.ping(received: 0), internetAccess: .unreachable(reason: "Timed out"))
        #expect(NetworkCheck.finding(in: health) == .internetUnreachable)
    }

    @Test func failedLookupWhileInternetAnswersIsDNSNotResponding() {
        #expect(NetworkCheck.finding(in: Self.health(dnsLookup: .failed(reason: "Timed out"))) == .dnsNotResponding)
    }

    /// 外部 ping も返らないなら DNS のせいとは言えない
    @Test func failedLookupWithoutPingRepliesIsNotDNSNotResponding() {
        let health = Self.health(internetPing: Self.ping(received: 0, lossRate: 1, average: nil), dnsLookup: .failed(reason: "Timed out"))
        #expect(NetworkCheck.finding(in: health) != .dnsNotResponding)
    }

    @Test func captivePortalNeedsSignIn() {
        #expect(NetworkCheck.finding(in: Self.health(internetAccess: .captivePortal)) == .captivePortal)
    }

    /// 10% ちょうどからロスとし、100ms ちょうどはまだ遅延にしない
    @Test func lossAndLatencyThresholds() {
        #expect(NetworkCheck.finding(in: Self.health(internetPing: Self.ping(lossRate: 0.09))) == nil)
        #expect(NetworkCheck.finding(in: Self.health(internetPing: Self.ping(lossRate: 0.1))) == .packetLoss)
        #expect(NetworkCheck.finding(in: Self.health(internetPing: Self.ping(average: 100))) == nil)
        #expect(NetworkCheck.finding(in: Self.health(internetPing: Self.ping(average: 100.1))) == .highLatency)
    }

    @Test func lossTakesPriorityOverLatency() {
        #expect(NetworkCheck.finding(in: Self.health(internetPing: Self.ping(lossRate: 0.5, average: 300))) == .packetLoss)
    }

    /// RSSI は -70 未満、SNR は 20 未満で弱いとする
    @Test func weakWiFiThresholds() {
        #expect(NetworkCheck.finding(in: Self.health(wifi: Self.wifi(rssi: -70, noise: -95))) == nil)
        #expect(NetworkCheck.finding(in: Self.health(wifi: Self.wifi(rssi: -71, noise: -95))) == .weakWiFiSignal)
        #expect(NetworkCheck.finding(in: Self.health(wifi: Self.wifi(rssi: -60, noise: -80))) == nil)
        #expect(NetworkCheck.finding(in: Self.health(wifi: Self.wifi(rssi: -60, noise: -79))) == .weakWiFiSignal)
    }

    @Test func failedSpeedTestKeepsReasonAsNote() {
        let health = Self.health(lastSpeedTest: SpeedTestRecord(date: Date(timeIntervalSince1970: 0), outcome: .failed(reason: "Timed out")))
        #expect(NetworkCheck.finding(in: health) == .speedTestFailed(reason: "Timed out"))
        #expect(NetworkCheck.status(of: health).note == "Timed out")
        #expect(!NetworkCheck.status(of: health).isFailed)
    }

    /// 速度の値そのものは判定しない（遅くても正常）
    @Test func slowSpeedTestIsOK() {
        let speed = SpeedTestRecord.Speed(downloadBitsPerSecond: 1_000, uploadBitsPerSecond: 1_000, responsiveness: 10, baseRoundTripMilliseconds: 500)
        #expect(NetworkCheck.finding(in: Self.health(lastSpeedTest: SpeedTestRecord(date: Date(timeIntervalSince1970: 0), outcome: .succeeded(speed)))) == nil)
    }

    // MARK: - 優先順位と除外

    @Test func offlineTakesPriorityOverWeakWiFi() {
        let health = Self.health(pathStatus: .unsatisfied, wifi: Self.wifi(rssi: -90, noise: -95))
        #expect(NetworkCheck.finding(in: health) == .offline)
    }

    @Test func routerFailureTakesPriorityOverDNSAndWarnings() {
        let health = Self.health(
            routerPing: Self.ping(received: 0),
            internetPing: Self.ping(received: 0, lossRate: 1, average: nil),
            dnsLookup: .failed(reason: "Timed out"),
            internetAccess: .unreachable(reason: "Timed out"),
            wifi: Self.wifi(rssi: -90, noise: -95)
        )
        #expect(NetworkCheck.finding(in: health) == .routerNotResponding(routerAddress: "192.168.1.1"))
    }

    /// ICMP を落とすルーターでも、インターネットに届いていれば失敗にしない
    @Test func silentRouterWithReachableInternetIsOK() {
        #expect(NetworkCheck.finding(in: Self.health(routerPing: Self.ping(received: 0), internetAccess: .reachable)) == nil)
    }

    /// 計測は回線を飽和させるので、ping と到達確認から出す問題は計測中は見ない
    @Test func speedTestSuppressesPingAndReachabilityFindings() {
        let unreachable = Self.health(
            routerPing: Self.ping(received: 0),
            internetPing: Self.ping(received: 0, lossRate: 1, average: nil),
            internetAccess: .unreachable(reason: "Timed out"),
            isTestingSpeed: true
        )
        #expect(NetworkCheck.finding(in: unreachable) == nil)
        #expect(NetworkCheck.finding(in: Self.health(internetPing: Self.ping(lossRate: 0.5), isTestingSpeed: true)) == nil)
        #expect(NetworkCheck.finding(in: Self.health(internetPing: Self.ping(average: 500), isTestingSpeed: true)) == nil)
    }

    @Test func speedTestStillReportsOfflineAndDNS() {
        #expect(NetworkCheck.finding(in: Self.health(pathStatus: .unsatisfied, isTestingSpeed: true)) == .offline)
        #expect(NetworkCheck.finding(in: Self.health(dnsLookup: .failed(reason: "Timed out"), isTestingSpeed: true)) == .dnsNotResponding)
    }

    // MARK: - 接続系の失敗

    @Test func onlyConnectionFindingsAreConnectionFailures() {
        let connection: [Finding] = [.offline, .routerNotResponding(routerAddress: "192.168.1.1"), .internetUnreachable, .dnsNotResponding]
        let others: [Finding] = [.captivePortal, .packetLoss, .highLatency, .weakWiFiSignal, .speedTestFailed(reason: "x")]
        #expect(connection.allSatisfy { $0.isConnectionFailure })
        #expect(connection.allSatisfy { $0.status.isFailed })
        #expect(!others.contains { $0.isConnectionFailure })
        #expect(others.allSatisfy { if case .warning = $0.status { true } else { false } })
    }

    // MARK: - 訳

    @Test func reasonsHaveJapaneseTranslations() {
        let japanese = Locale(identifier: "ja_JP")
        let pairs: [(LocalizedStringResource, String)] = [
            ("Offline", "オフライン"),
            ("Router not responding", "ルーターが応答しません"),
            ("Can't reach the internet", "インターネットに接続できません"),
            ("DNS not responding", "DNS が応答しません"),
            ("Sign-in required", "ネットワークへのログインが必要です"),
            ("Packet loss", "パケットロスがあります"),
            ("High latency", "遅延が大きくなっています"),
            ("Weak Wi-Fi signal", "Wi-Fi の電波が弱くなっています"),
            ("Speed test failed", "速度を計測できませんでした"),
        ]
        for (resource, expected) in pairs {
            #expect(String(localized: resource, language: japanese) == expected)
        }
    }

    // MARK: - 作るもの

    private static func ping(received: Int = 10, lossRate: Double = 0, average: Double? = 20) -> NetworkHealth.PingResult {
        NetworkHealth.PingResult(destination: "1.1.1.1", receivedCount: received, lossRate: lossRate, averageMilliseconds: average)
    }

    private static func wifi(rssi: Int, noise: Int) -> NetworkHealth.WiFiInfo {
        NetworkHealth.WiFiInfo(
            interfaceName: "en0",
            ssid: nil,
            rssi: rssi,
            noise: noise,
            channelNumber: 36,
            band: .fiveGigahertz,
            channelWidth: 80,
            phyMode: "802.11ax",
            transmitRate: 600
        )
    }

    /// 既定はすべて正常な値
    private static func health(
        pathStatus: NetworkHealth.PathStatus = .satisfied,
        routerAddress: String? = "192.168.1.1",
        routerPing: NetworkHealth.PingResult? = ping(),
        internetPing: NetworkHealth.PingResult? = ping(),
        dnsLookup: NetworkHealth.DNSLookup? = .resolved(milliseconds: 10),
        internetAccess: NetworkHealth.InternetAccess? = .reachable,
        wifi: NetworkHealth.WiFiInfo? = wifi(rssi: -50, noise: -95),
        lastSpeedTest: SpeedTestRecord? = nil,
        isTestingSpeed: Bool = false
    ) -> NetworkHealth {
        NetworkHealth(
            pathStatus: pathStatus,
            interface: .wifi,
            isExpensive: false,
            isConstrained: false,
            routerAddress: routerAddress,
            dnsServers: ["192.168.1.1"],
            routerPing: routerPing,
            internetPing: internetPing,
            dnsLookup: dnsLookup,
            internetAccess: internetAccess,
            wifi: wifi,
            lastSpeedTest: lastSpeedTest,
            isTestingSpeed: isTestingSpeed
        )
    }
}
