import Foundation

/**
 ある時点のネットワークの状態。チェックごとに作り直し、項目の詳細として持つ。
 各チェックの結果が nil のものは、まだ測っていない・前提（経路・Wi-Fi）が無くて測れないもの
 */
struct NetworkHealth: Hashable, Sendable {
    /// `NWPath.Status` を Sendable な値で持つ
    enum PathStatus: Hashable, Sendable {
        case satisfied
        case unsatisfied
        /// VPN のオンデマンドなど、使おうとすればつながる
        case requiresConnection
    }

    /// いま使っている経路のインターフェイス。`none` はどのインターフェイスも使えない
    enum Interface: Hashable, Sendable {
        case wifi
        case wiredEthernet
        case cellular
        case other
        case none
    }

    struct PingResult: Hashable, Sendable {
        let destination: String
        let receivedCount: Int
        /// 0〜1。ping の出す値をそのまま使う（重複して届いた応答があると送信数と受信数から出す値と食い違う）
        let lossRate: Double
        /// 1つも返ってこなければ nil
        let averageMilliseconds: Double?
    }

    enum DNSLookup: Hashable, Sendable {
        case resolved(milliseconds: Double)
        case failed(reason: String)

        var failureReason: String? {
            if case .failed(let reason) = self {
                reason
            } else {
                nil
            }
        }
    }

    enum InternetAccess: Hashable, Sendable {
        case reachable
        case unreachable(reason: String)
        /// 応答は返るが中身が書き換えられている（ホテルなどのログイン画面）
        case captivePortal

        var failureReason: String? {
            if case .unreachable(let reason) = self {
                reason
            } else {
                nil
            }
        }
    }

    struct WiFiInfo: Hashable, Sendable {
        enum Band: Hashable, Sendable {
            case twoPointFourGigahertz
            case fiveGigahertz
            case sixGigahertz
            case unknown
        }

        let interfaceName: String
        /// 位置情報の許可が無いと読めないので nil になる
        let ssid: String?
        /// dBm
        let rssi: Int
        /// dBm
        let noise: Int
        let channelNumber: Int
        let band: Band
        /// MHz。読めなければ nil
        let channelWidth: Int?
        /// 規格の名前（`802.11ax` など）。読めなければ nil
        let phyMode: String?
        /// Mbps
        let transmitRate: Double

        /// dB。電波が強くても雑音が大きいと速度が落ちるので、強さと合わせて見る
        var signalToNoise: Int {
            rssi - noise
        }
    }

    let pathStatus: PathStatus
    let interface: Interface
    /// テザリングなど、通信量に気を遣う経路
    let isExpensive: Bool
    /// 低データモード
    let isConstrained: Bool
    let routerAddress: String?
    let dnsServers: [String]
    let routerPing: PingResult?
    /// 外部の宛先への ping
    let internetPing: PingResult?
    let dnsLookup: DNSLookup?
    let internetAccess: InternetAccess?
    let wifi: WiFiInfo?
    let lastSpeedTest: SpeedTestRecord?
    let isTestingSpeed: Bool
}
