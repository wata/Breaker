import Foundation
import Network
import Synchronization

/// `NWPath` のうち、ヘルスチェックに使うところだけを Sendable な値で持つ
struct NetworkPath: Hashable, Sendable {
    let status: NetworkHealth.PathStatus
    let interface: NetworkHealth.Interface
    let isExpensive: Bool
    let isConstrained: Bool
}

extension NetworkPath {
    /**
     `NWPath` はテストで作れないので、写しの元を作れる型（`NWPath.Status`・`NWInterface.InterfaceType`）で受け取る。
     VPN 中は Wi-Fi と `other`（utun）が同時に使われるので、物理的な経路を優先して1つに決める
     */
    init(status: NWPath.Status, usedInterfaceTypes: [NWInterface.InterfaceType], isExpensive: Bool, isConstrained: Bool) {
        self.status = switch status {
        case .satisfied:
            .satisfied

        case .requiresConnection:
            .requiresConnection

        case .unsatisfied:
            .unsatisfied

        @unknown default:
            .unsatisfied
        }
        let priority: [(NWInterface.InterfaceType, NetworkHealth.Interface)] = [
            (.wifi, .wifi),
            (.wiredEthernet, .wiredEthernet),
            (.cellular, .cellular),
            (.other, .other),
        ]
        interface = priority.first { usedInterfaceTypes.contains($0.0) }?.1 ?? .none
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    init(_ path: NWPath) {
        let types: [NWInterface.InterfaceType] = [.wifi, .wiredEthernet, .cellular, .other]
        self.init(
            status: path.status,
            usedInterfaceTypes: types.filter { path.usesInterfaceType($0) },
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}

/// テストで経路を差し替えるための窓口
protocol PathMonitoring: Sendable {
    func current() async -> NetworkPath
}

/**
 `NWPathMonitor` は start 直後の `currentPath` がまだ確定していないことがあるので、作ったら持ち続けて最新の update を覚えておく。
 チェックのたびに作り直すと毎回最初の update を待つことになる
 */
final class PathMonitor: PathMonitoring {
    private struct State {
        var latest: NetworkPath?
        var waiters = [UUID: CheckedContinuation<NetworkPath, Never>]()
    }

    private let monitor = NWPathMonitor()
    private let state = Mutex(State())
    private let firstUpdateTimeout: DispatchTimeInterval = .seconds(1)

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            receive(NetworkPath(path))
        }
        monitor.start(queue: DispatchQueue(label: "PathMonitor"))
    }

    deinit {
        monitor.cancel()
    }

    func current() async -> NetworkPath {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let latest = state.withLock { state in
                if state.latest == nil {
                    state.waiters[id] = continuation
                }
                return state.latest
            }
            if let latest {
                continuation.resume(returning: latest)
                return
            }
            // update が来ないまま待ち続けないよう、期限が来たらその時点の currentPath で答える
            // 待っている continuation を必ず resume するため、self は強く持つ（最長でも期限までしか延びない）
            DispatchQueue.global().asyncAfter(deadline: .now() + firstUpdateTimeout) { [self] in
                let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
                waiter?.resume(returning: NetworkPath(monitor.currentPath))
            }
        }
    }

    private func receive(_ path: NetworkPath) {
        let waiters = state.withLock { state in
            state.latest = path
            defer { state.waiters.removeAll() }
            return state.waiters.values
        }
        for waiter in waiters {
            waiter.resume(returning: path)
        }
    }
}
