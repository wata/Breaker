import Foundation
import SystemConfiguration

/// いまの主経路のルーターと DNS サーバー。configd が持っている値で、どれも未接続なら空になる
struct GatewayInfo: Hashable, Sendable {
    let routerAddress: String?
    let dnsServers: [String]
}

extension GatewayInfo {
    /// `State:/Network/Global/IPv4` と `State:/Network/Global/DNS` の辞書から作る。キーが無い・型が違うものは無いものとして扱う
    init(ipv4: [String: Any]?, dns: [String: Any]?) {
        routerAddress = ipv4?["Router"] as? String
        dnsServers = dns?["ServerAddresses"] as? [String] ?? []
    }
}

/// テストでルーターと DNS サーバーを差し替えるための窓口
protocol GatewayReading: Sendable {
    func read() -> GatewayInfo
}

/// `netstat -rn` や `scutil` を走らせずに、SystemConfiguration から同じ値を直接読む
struct GatewayReader: GatewayReading {
    func read() -> GatewayInfo {
        let store = SCDynamicStoreCreate(nil, "Breaker" as CFString, nil, nil)
        let ipv4 = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any] }
        let dns = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/DNS" as CFString) as? [String: Any] }
        return GatewayInfo(ipv4: ipv4, dns: dns)
    }
}
