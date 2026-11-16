import Foundation

/// 速度計測の最新の状態。`SpeedTestScheduler` は MainActor にあるので、Source からは値の写しで受け取る
struct SpeedTestSnapshot: Hashable, Sendable {
    let lastRecord: SpeedTestRecord?
    let isMeasuring: Bool

    static let idle = SpeedTestSnapshot(lastRecord: nil, isMeasuring: false)
}

/**
 ネットワークの状態を測り、項目を1つ返す。`ItemDiscovery` は全 Source を待って一覧を作るので、
 時間のかかるチェック（ping・DNS・到達確認）は並行に走らせ、どれも6秒ほどで打ち切られる長さに収める
 */
struct NetworkSource: ItemSource {
    typealias SpeedTestProvider = @Sendable () async -> SpeedTestSnapshot

    /// 外部への ping の宛先。DNS が壊れていても届くよう、名前ではなくアドレスにする
    static let internetPingDestination = "1.1.1.1"

    let kind = MonitoredItem.Kind.network

    private let pathMonitor: any PathMonitoring
    private let gatewayReader: any GatewayReading
    private let pinger: any Pinging
    private let dnsResolver: any DNSResolving
    private let internetProbe: any InternetProbing
    private let wifiReader: any WiFiReading
    private let speedTest: SpeedTestProvider
    private let history: NetworkCheckHistory
    private let now: @Sendable () -> Date

    /// `AppModel` は起動中ずっと同じ Source を使い続けるので、揺れ止めの記録（`history`）もその間引き継がれる
    init(
        pathMonitor: any PathMonitoring = PathMonitor(),
        gatewayReader: any GatewayReading = GatewayReader(),
        pinger: any Pinging = Ping(),
        dnsResolver: any DNSResolving = DNSResolver(),
        internetProbe: any InternetProbing = InternetProbe(),
        wifiReader: any WiFiReading = WiFiReader(),
        speedTest: @escaping SpeedTestProvider = { .idle },
        history: NetworkCheckHistory = NetworkCheckHistory(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pathMonitor = pathMonitor
        self.gatewayReader = gatewayReader
        self.pinger = pinger
        self.dnsResolver = dnsResolver
        self.internetProbe = internetProbe
        self.wifiReader = wifiReader
        self.speedTest = speedTest
        self.history = history
        self.now = now
    }

    func items() async throws -> [MonitoredItem] {
        let health = try await measure()
        let status = await history.record(health: health, finding: NetworkCheck.finding(in: health), now: now())
        return [MonitoredItem(key: "health", name: kind.title, status: status, detail: .network(health))]
    }

    /// 速度計測を自動で走らせてよいかを決めるのに使う。まだ一度も測っていなければ nil
    func latestCheck() async -> NetworkCheckHistory.Check? {
        await history.latest
    }

    /**
     オフライン（経路が unsatisfied）なら、ping・DNS・到達確認はどれも失敗すると分かっているので走らせない。
     ゲートウェイと Wi-Fi はすぐ読めて、Wi-Fi の電源や電波の様子はオフラインの原因を探す手がかりになるので読む。
     速度の計測は回線を飽和させて ping や到達確認を悪くするので、確認の前後どちらかで計測中なら計測中として判定させる
     */
    private func measure() async throws -> NetworkHealth {
        let path = await pathMonitor.current()
        let gateway = gatewayReader.read()
        let speedBefore = await speedTest()
        var routerPing: NetworkHealth.PingResult?
        var internetPing: NetworkHealth.PingResult?
        var dnsLookup: NetworkHealth.DNSLookup?
        var internetAccess: NetworkHealth.InternetAccess?
        if path.status != .unsatisfied {
            async let router = pingRouter(gateway.routerAddress)
            async let internet = pinger.ping(Self.internetPingDestination)
            async let lookup = dnsResolver.lookup()
            async let access = internetProbe.probe()
            (routerPing, internetPing, dnsLookup, internetAccess) = try await (router, internet, lookup, access)
        }
        // オフラインの経路は使っているインターフェイスが無い（none）ので、そのときも Wi-Fi を読む
        let wifi = path.interface == .wifi || path.status == .unsatisfied ? wifiReader.read() : nil
        let speedAfter = await speedTest()
        return NetworkHealth(
            pathStatus: path.status,
            interface: path.interface,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            routerAddress: gateway.routerAddress,
            dnsServers: gateway.dnsServers,
            routerPing: routerPing,
            internetPing: internetPing,
            dnsLookup: dnsLookup,
            internetAccess: internetAccess,
            wifi: wifi,
            lastSpeedTest: speedAfter.lastRecord,
            isTestingSpeed: speedBefore.isMeasuring || speedAfter.isMeasuring
        )
    }

    /// ルーターのアドレスが無い（経路が VPN だけなど）ときは打つ先が無いので、測っていない（nil）とする
    private func pingRouter(_ address: String?) async throws -> NetworkHealth.PingResult? {
        if let address {
            try await pinger.ping(address)
        } else {
            nil
        }
    }
}

/**
 接続系の失敗の揺れ止め。Wi-Fi の切り替えや一時的な取りこぼしで通知しないよう、2回続けたときだけ失敗にする。
 スリープ明けはつながり直す途中で失敗しやすいので、明けて最初の1回は数えない
 */
actor NetworkCheckHistory {
    private let lastWakeDate: @Sendable () -> Date?

    init(lastWakeDate: @escaping @Sendable () -> Date? = { WakeMonitor.shared.lastWakeDate }) {
        self.lastWakeDate = lastWakeDate
    }

    struct Check: Hashable, Sendable {
        let health: NetworkHealth
        /// 揺れ止めをかける前の判定。速度計測を見送るかはこちらで決める（1回の失敗でも回線は不安定）
        let finding: NetworkCheck.Finding?
    }

    /// 失敗にするのに要る、続けて見た接続系の失敗の回数
    static let failureThreshold = 2

    private(set) var latest: Check?
    private var consecutiveFailures = 0
    private var lastCheckDate: Date?

    func record(health: NetworkHealth, finding: NetworkCheck.Finding?, now: Date) -> ItemStatus {
        let isAfterWake = if
            let lastCheckDate,
            let wakeDate = lastWakeDate()
        {
            wakeDate > lastCheckDate
        } else {
            false
        }
        lastCheckDate = now
        latest = Check(health: health, finding: finding)
        guard let finding, finding.isConnectionFailure else {
            consecutiveFailures = 0
            return finding?.status ?? .ok
        }
        // 眠る前の失敗と明けてからの失敗は別の出来事なので、続けて数えない
        consecutiveFailures = isAfterWake ? 0 : consecutiveFailures + 1
        if consecutiveFailures >= Self.failureThreshold {
            return finding.status
        }
        return .warning(
            reason: String(localized: "Checking connection…", comment: "Reason of the network item when a connection check failed once and is being confirmed. The tentative cause is shown separately"),
            note: finding.status.reason
        )
    }
}
