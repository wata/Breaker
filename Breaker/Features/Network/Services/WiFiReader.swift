import CoreWLAN
import Foundation

/// テストで Wi-Fi の状態を差し替えるための窓口
protocol WiFiReading: Sendable {
    /// Wi-Fi のインターフェイスが無い・電源が切れているときは nil
    func read() -> NetworkHealth.WiFiInfo?
}

/// CoreWLAN から今つながっている Wi-Fi の電波の状態を読む。SSID は位置情報の許可が無いと nil で返ってくる
struct WiFiReader: WiFiReading {
    /// 設定で「Wi-Fi のネットワーク名を表示」をオンにしたか。位置情報を許可していても、オフなら SSID を読まない
    static let showsNetworkNameKey = "showsWiFiNetworkName"

    /// 設定を変えたら次のチェックから効くよう、毎回読む
    private let showsNetworkName: @Sendable () -> Bool

    init(showsNetworkName: @escaping @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: WiFiReader.showsNetworkNameKey) }) {
        self.showsNetworkName = showsNetworkName
    }

    func read() -> NetworkHealth.WiFiInfo? {
        guard
            let interface = CWWiFiClient.shared().interface(),
            interface.powerOn(),
            let name = interface.interfaceName
        else {
            return nil
        }
        let channel = interface.wlanChannel()
        return NetworkHealth.WiFiInfo(
            interfaceName: name,
            ssid: showsNetworkName() ? interface.ssid() : nil,
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement(),
            channelNumber: channel?.channelNumber ?? 0,
            band: Self.band(channel?.channelBand ?? .bandUnknown),
            channelWidth: Self.megahertz(channel?.channelWidth ?? .widthUnknown),
            phyMode: Self.name(of: interface.activePHYMode()),
            transmitRate: interface.transmitRate()
        )
    }

    static func band(_ band: CWChannelBand) -> NetworkHealth.WiFiInfo.Band {
        switch band {
        case .band2GHz:
            .twoPointFourGigahertz

        case .band5GHz:
            .fiveGigahertz

        case .band6GHz:
            .sixGigahertz

        case .bandUnknown:
            .unknown

        @unknown default:
            .unknown
        }
    }

    static func megahertz(_ width: CWChannelWidth) -> Int? {
        switch width {
        case .width20MHz:
            20

        case .width40MHz:
            40

        case .width80MHz:
            80

        case .width160MHz:
            160

        case .widthUnknown:
            nil

        @unknown default:
            nil
        }
    }

    /// 未接続（`modeNone`）や SDK より新しい規格は名前を付けられないので nil
    static func name(of phyMode: CWPHYMode) -> String? {
        switch phyMode {
        case .mode11a:
            "802.11a"

        case .mode11b:
            "802.11b"

        case .mode11g:
            "802.11g"

        case .mode11n:
            "802.11n"

        case .mode11ac:
            "802.11ac"

        case .mode11ax:
            "802.11ax"

        case .mode11be:
            "802.11be"

        case .modeNone:
            nil

        @unknown default:
            nil
        }
    }
}
