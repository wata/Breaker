import Testing
@testable import Breaker

struct GatewayInfoTests {
    /// `SCDynamicStoreCopyValue` で `State:/Network/Global/IPv4`・`…/DNS` を実際に読んだ値と同じ形
    @Test func readsRouterAndDNSServers() {
        let info = GatewayInfo(
            ipv4: ["PrimaryInterface": "en0", "PrimaryService": "BC50CEB4-C7DF-428F-BE62-19C83B6B9DF6", "Router": "192.168.11.1"],
            dns: ["SearchDomains": ["flets-east.jp"], "ServerAddresses": ["2404:1a8:7f01:b::3", "192.168.11.1"]]
        )
        #expect(info == GatewayInfo(routerAddress: "192.168.11.1", dnsServers: ["2404:1a8:7f01:b::3", "192.168.11.1"]))
    }

    @Test func offline() {
        #expect(GatewayInfo(ipv4: nil, dns: nil) == GatewayInfo(routerAddress: nil, dnsServers: []))
    }

    /// IPv6 だけの経路では IPv4 の辞書はあっても Router が無いことがある
    @Test func missingKeysAndWrongTypes() {
        let info = GatewayInfo(ipv4: ["PrimaryInterface": "en0"], dns: ["ServerAddresses": "1.1.1.1"])
        #expect(info == GatewayInfo(routerAddress: nil, dnsServers: []))
    }
}
