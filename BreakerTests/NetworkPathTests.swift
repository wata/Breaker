import Network
import Testing
@testable import Breaker

struct NetworkPathTests {
    @Test func satisfiedWiFi() {
        let path = NetworkPath(status: .satisfied, usedInterfaceTypes: [.wifi], isExpensive: false, isConstrained: true)
        #expect(path == NetworkPath(status: .satisfied, interface: .wifi, isExpensive: false, isConstrained: true))
    }

    /// VPN 中は utun（other）も使われるが、物理的な経路を答える
    @Test func physicalInterfaceWinsOverVPN() {
        let path = NetworkPath(status: .satisfied, usedInterfaceTypes: [.other, .wiredEthernet], isExpensive: false, isConstrained: false)
        #expect(path.interface == .wiredEthernet)
    }

    @Test func tetheringIsExpensive() {
        let path = NetworkPath(status: .satisfied, usedInterfaceTypes: [.cellular], isExpensive: true, isConstrained: false)
        #expect(path == NetworkPath(status: .satisfied, interface: .cellular, isExpensive: true, isConstrained: false))
    }

    @Test func noInterface() {
        let path = NetworkPath(status: .unsatisfied, usedInterfaceTypes: [], isExpensive: false, isConstrained: false)
        #expect(path == NetworkPath(status: .unsatisfied, interface: .none, isExpensive: false, isConstrained: false))
    }

    @Test func requiresConnection() {
        let path = NetworkPath(status: .requiresConnection, usedInterfaceTypes: [.other], isExpensive: false, isConstrained: false)
        #expect(path.status == .requiresConnection)
        #expect(path.interface == .other)
    }
}
