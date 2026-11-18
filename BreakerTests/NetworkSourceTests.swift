import Foundation
import Synchronization
import Testing
@testable import Breaker

struct NetworkSourceTests {
    @Test func healthyNetworkIsOK() async throws {
        let item = try await Self.source().onlyItem()
        #expect(item.status == .ok)
        #expect(item.kind == .network)
        guard case .network(let health) = item.detail else {
            Issue.record("詳細がネットワークではない")
            return
        }
        #expect(health.routerAddress == "192.168.1.1")
        #expect(health.dnsServers == ["192.168.1.1"])
        #expect(health.routerPing?.destination == "192.168.1.1")
        #expect(health.internetPing?.destination == NetworkSource.internetPingDestinations.first)
        #expect(health.dnsLookup == .resolved(milliseconds: 10))
        #expect(health.internetAccess == .reachable)
        #expect(health.wifi?.rssi == -50)
    }

    /// オフラインなら ping・DNS・到達確認はどれも失敗と分かっているので走らせない
    @Test func offlineSkipsNetworkChecks() async throws {
        let pinger = StubPinger()
        let item = try await Self.source(path: Self.path(status: .unsatisfied), pinger: pinger).onlyItem()
        #expect(pinger.hosts.isEmpty)
        guard case .network(let health) = item.detail else {
            Issue.record("詳細がネットワークではない")
            return
        }
        #expect(health.routerPing == nil)
        #expect(health.internetPing == nil)
        #expect(health.dnsLookup == nil)
        #expect(health.internetAccess == nil)
    }

    @Test func connectionFailureFailsOnlyWhenRepeated() async throws {
        let clock = StubClock()
        let source = Self.source(path: Self.path(status: .unsatisfied), clock: clock)
        let first = try await source.onlyItem()
        #expect(first.status.reason == "Checking connection…")
        #expect(first.status.note == "Offline")
        #expect(!first.isReportedAbnormal)
        clock.advance(by: 60)
        let second = try await source.onlyItem()
        #expect(second.status == .failed(reason: "Offline"))
        #expect(second.isReportedAbnormal)
    }

    @Test func recoveryResetsFailureCount() async throws {
        let clock = StubClock()
        let path = Mutex(Self.path(status: .unsatisfied))
        let source = Self.source(pathMonitor: StubPathMonitor { path.withLock { $0 } }, clock: clock)
        _ = try await source.onlyItem()
        path.withLock { $0 = Self.path() }
        clock.advance(by: 60)
        #expect(try await source.onlyItem().status == .ok)
        path.withLock { $0 = Self.path(status: .unsatisfied) }
        clock.advance(by: 60)
        #expect(try await source.onlyItem().status.reason == "Checking connection…")
    }

    /// 眠る前の失敗と続けて数えず、明けて最初の1回も数えない。失敗になるのはその後2回続けたとき
    @Test func firstCheckAfterWakeIsNotCounted() async throws {
        let clock = StubClock()
        let wakeDate = Mutex<Date?>(nil)
        let source = Self.source(path: Self.path(status: .unsatisfied), clock: clock, wakeDate: { wakeDate.withLock { $0 } })
        _ = try await source.onlyItem()
        clock.advance(by: 30)
        wakeDate.withLock { $0 = clock.now }
        clock.advance(by: 30)
        #expect(try await source.onlyItem().status.reason == "Checking connection…")
        clock.advance(by: 60)
        #expect(try await source.onlyItem().status.reason == "Checking connection…")
        clock.advance(by: 60)
        #expect(try await source.onlyItem().status == .failed(reason: "Offline"))
    }

    /// オフラインの原因を探す手がかりになるので、使っているインターフェイスが無くても Wi-Fi の様子は読む
    @Test func offlineStillReadsWiFi() async throws {
        let item = try await Self.source(path: Self.path(status: .unsatisfied)).onlyItem()
        #expect(item.networkHealth?.wifi != nil)
    }

    /// 接続系でない問題（遅延など）は揺れ止めをかけず、そのまま出す
    @Test func nonConnectionFindingIsShownImmediately() async throws {
        let pinger = StubPinger { host in Self.ping(host, average: NetworkSource.internetPingDestinations.contains(host) ? 300 : 2) }
        #expect(try await Self.source(pinger: pinger).onlyItem().status == .warning(reason: "High latency"))
    }

    /// 1つの事業者への経路だけが遅い回線でも、ほかの宛先に速く届けば遅延とはしない
    @Test func slowRouteToOneDestinationIsNotHighLatency() async throws {
        let pinger = StubPinger { host in Self.ping(host, average: host == "1.1.1.1" ? 300 : 10) }
        let item = try await Self.source(pinger: pinger).onlyItem()
        #expect(item.status == .ok)
        #expect(item.networkHealth?.internetPing?.destination == "8.8.8.8")
    }

    /// ロスがあると届いた分だけの平均になるので、遅延よりロスの少なさで選ぶ
    @Test func bestInternetPingPrefersLowerLoss() {
        let lossy = NetworkHealth.PingResult(destination: "1.1.1.1", receivedCount: 5, lossRate: 0.5, averageMilliseconds: 5)
        let slow = NetworkHealth.PingResult(destination: "8.8.8.8", receivedCount: 10, lossRate: 0, averageMilliseconds: 50)
        #expect(NetworkSource.bestInternetPing(of: [lossy, slow]) == slow)
        #expect(NetworkSource.bestInternetPing(of: []) == nil)
    }

    /// 同じ結果なら先に並んだ宛先を選び、チェックのたびに表示の宛先が入れ替わらないようにする
    @Test func bestInternetPingKeepsOrderOnTie() {
        let first = NetworkHealth.PingResult(destination: "1.1.1.1", receivedCount: 0, lossRate: 1, averageMilliseconds: nil)
        let second = NetworkHealth.PingResult(destination: "8.8.8.8", receivedCount: 0, lossRate: 1, averageMilliseconds: nil)
        #expect(NetworkSource.bestInternetPing(of: [first, second]) == first)
    }

    @Test func speedTestSnapshotGoesIntoHealth() async throws {
        let record = SpeedTestRecord(date: Date(timeIntervalSince1970: 0), outcome: .failed(reason: "Timed out"))
        let source = Self.source(speedTest: { SpeedTestSnapshot(lastRecord: record, isMeasuring: true) })
        let item = try await source.onlyItem()
        guard case .network(let health) = item.detail else {
            Issue.record("詳細がネットワークではない")
            return
        }
        #expect(health.lastSpeedTest == record)
        #expect(health.isTestingSpeed)
        #expect(item.status == .warning(reason: "Speed test failed", note: "Timed out"))
    }

    /// 確認を始めた後に速度の計測が始まると、遅い ping を計測のせいと見なせず要確認にしてしまうので、後で読んだ計測中も効かせる
    @Test func speedTestStartedDuringChecksCountsAsTesting() async throws {
        let calls = Mutex(0)
        let pinger = StubPinger { host in Self.ping(host, average: NetworkSource.internetPingDestinations.contains(host) ? 300 : 2) }
        let source = Self.source(pinger: pinger, speedTest: {
            let isMeasuring = calls.withLock { count in
                count += 1
                return count > 1
            }
            return SpeedTestSnapshot(lastRecord: nil, isMeasuring: isMeasuring)
        })
        let item = try await source.onlyItem()
        guard case .network(let health) = item.detail else {
            Issue.record("詳細がネットワークではない")
            return
        }
        #expect(health.isTestingSpeed)
        #expect(item.status == .ok)
    }

    @Test func missingRouterAddressSkipsRouterPing() async throws {
        let pinger = StubPinger()
        let gateway = GatewayInfo(routerAddress: nil, dnsServers: [])
        let item = try await Self.source(gateway: gateway, pinger: pinger).onlyItem()
        #expect(pinger.hosts == NetworkSource.internetPingDestinations.sorted())
        guard case .network(let health) = item.detail else {
            Issue.record("詳細がネットワークではない")
            return
        }
        #expect(health.routerPing == nil)
    }

    /// 有線では Wi-Fi の電波は経路と関係ないので読まない
    @Test func wiredPathHasNoWiFi() async throws {
        let item = try await Self.source(path: Self.path(interface: .wiredEthernet)).onlyItem()
        guard case .network(let health) = item.detail else {
            Issue.record("詳細がネットワークではない")
            return
        }
        #expect(health.wifi == nil)
    }

    /// 4つのチェックがそれぞれ 0.5 秒かかっても、並行なら合計は 2 秒より十分短い
    @Test func checksRunConcurrently() async throws {
        let delay = Duration.milliseconds(500)
        let source = Self.source(
            pinger: StubPinger(delay: delay),
            dnsResolver: StubDNSResolver(delay: delay),
            internetProbe: StubInternetProbe(delay: delay)
        )
        let start = ContinuousClock.now
        _ = try await source.onlyItem()
        #expect(ContinuousClock.now - start < .milliseconds(1500))
    }

    @Test func latestCheckKeepsUndebouncedFinding() async throws {
        let source = Self.source(path: Self.path(status: .unsatisfied, isExpensive: true))
        #expect(await source.latestCheck() == nil)
        let item = try await source.onlyItem()
        let check = try #require(await source.latestCheck())
        #expect(!item.status.isFailed)
        #expect(check.finding == .offline)
        #expect(check.finding?.isConnectionFailure == true)
        #expect(check.health.pathStatus == .unsatisfied)
        #expect(check.health.isExpensive)
    }
}

// MARK: - 部品

extension NetworkSourceTests {
    static func source(
        path: NetworkPath = path(),
        pathMonitor: StubPathMonitor? = nil,
        gateway: GatewayInfo = GatewayInfo(routerAddress: "192.168.1.1", dnsServers: ["192.168.1.1"]),
        pinger: StubPinger = StubPinger(),
        dnsResolver: StubDNSResolver = StubDNSResolver(),
        internetProbe: StubInternetProbe = StubInternetProbe(),
        speedTest: @escaping NetworkSource.SpeedTestProvider = { .idle },
        clock: StubClock = StubClock(),
        wakeDate: @escaping @Sendable () -> Date? = { nil }
    ) -> NetworkSource {
        NetworkSource(
            pathMonitor: pathMonitor ?? StubPathMonitor { path },
            gatewayReader: StubGatewayReader(gateway: gateway),
            pinger: pinger,
            dnsResolver: dnsResolver,
            internetProbe: internetProbe,
            wifiReader: StubWiFiReader(),
            speedTest: speedTest,
            history: NetworkCheckHistory(lastWakeDate: wakeDate),
            now: { clock.now }
        )
    }

    /// 実際の経路と同じく、オフラインでは使っているインターフェイスが無い
    static func path(
        status: NetworkHealth.PathStatus = .satisfied,
        interface: NetworkHealth.Interface? = nil,
        isExpensive: Bool = false
    ) -> NetworkPath {
        NetworkPath(status: status, interface: interface ?? (status == .unsatisfied ? .none : .wifi), isExpensive: isExpensive, isConstrained: false)
    }

    static func ping(_ host: String, average: Double = 10) -> NetworkHealth.PingResult {
        NetworkHealth.PingResult(destination: host, receivedCount: 10, lossRate: 0, averageMilliseconds: average)
    }
}

/// 他のテストの部品と名前がぶつからないよう、このテストの中に入れる
extension NetworkSourceTests {
    struct StubPathMonitor: PathMonitoring {
        let path: @Sendable () -> NetworkPath

        func current() async -> NetworkPath {
            path()
        }
    }

    struct StubGatewayReader: GatewayReading {
        let gateway: GatewayInfo

        func read() -> GatewayInfo {
            gateway
        }
    }

    final class StubPinger: Pinging {
        private let delay: Duration
        private let result: @Sendable (String) -> NetworkHealth.PingResult
        private let recordedHosts = Mutex([String]())

        init(delay: Duration = .zero, result: @escaping @Sendable (String) -> NetworkHealth.PingResult = { NetworkSourceTests.ping($0) }) {
            self.delay = delay
            self.result = result
        }

        /// 並行に呼ばれるので、呼ばれた順ではなく並べ替えて返す
        var hosts: [String] {
            recordedHosts.withLock { $0.sorted() }
        }

        func ping(_ host: String) async throws -> NetworkHealth.PingResult {
            recordedHosts.withLock { $0.append(host) }
            try await Task.sleep(for: delay)
            return result(host)
        }
    }

    struct StubDNSResolver: DNSResolving {
        var delay = Duration.zero

        func lookup() async -> NetworkHealth.DNSLookup {
            try? await Task.sleep(for: delay)
            return .resolved(milliseconds: 10)
        }
    }

    struct StubInternetProbe: InternetProbing {
        var delay = Duration.zero

        func probe() async -> NetworkHealth.InternetAccess {
            try? await Task.sleep(for: delay)
            return .reachable
        }
    }

    struct StubWiFiReader: WiFiReading {
        func read() -> NetworkHealth.WiFiInfo? {
            NetworkHealth.WiFiInfo(
                interfaceName: "en0",
                ssid: nil,
                rssi: -50,
                noise: -95,
                channelNumber: 36,
                band: .fiveGigahertz,
                channelWidth: 80,
                phyMode: "802.11ax",
                transmitRate: 866
            )
        }
    }

    final class StubClock: Sendable {
        private let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

        var now: Date {
            date.withLock { $0 }
        }

        func advance(by interval: TimeInterval) {
            date.withLock { $0 += interval }
        }
    }
}

private extension NetworkSource {
    func onlyItem() async throws -> MonitoredItem {
        let items = try await items()
        try #require(items.count == 1)
        return items[0]
    }
}
