import Foundation
import Synchronization

/// テストで名前解決の結果を差し替えるための窓口
protocol DNSResolving: Sendable {
    func lookup() async -> NetworkHealth.DNSLookup
}

/// システムのリゾルバ（`getaddrinfo`）で名前を引き、かかった時間を測る。アプリが実際に使うのと同じ経路で確かめるため、DNS サーバーへ直接は問い合わせない
struct DNSResolver: DNSResolving {
    enum Outcome: Hashable, Sendable {
        /// `getaddrinfo` の戻り値（0 が成功、それ以外は `EAI_*`）
        case finished(code: Int32)
        /// 期限までに `getaddrinfo` が戻らなかった
        case timedOut
    }

    var hostName = "www.apple.com"
    var timeout: Duration = .seconds(3)

    func lookup() async -> NetworkHealth.DNSLookup {
        let start = ContinuousClock.now
        let outcome = await resolve()
        return Self.makeLookup(outcome: outcome, elapsed: ContinuousClock.now - start)
    }

    static func makeLookup(outcome: Outcome, elapsed: Duration) -> NetworkHealth.DNSLookup {
        switch outcome {
        case .finished(code: 0):
            return .resolved(milliseconds: elapsed / .milliseconds(1))

        case .finished(let code):
            return .failed(reason: String(cString: gai_strerror(code)))

        case .timedOut:
            // getaddrinfo の失敗と同じく、システムの英語の説明（"Operation timed out"）で揃える
            return .failed(reason: String(cString: strerror(ETIMEDOUT)))
        }
    }

    /**
     `getaddrinfo` はブロッキングで取り消せないので、協調スレッドプールの外で回す。
     期限が来たらスレッドは残したまま先に答え、遅れて終わった側は何もしない（continuation は先に来た方だけが resume する）
     */
    private func resolve() async -> Outcome {
        await withCheckedContinuation { continuation in
            let pending = PendingContinuation(continuation)
            DispatchQueue.global().async { [hostName] in
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                let code = getaddrinfo(hostName, nil, &hints, &result)
                if let result {
                    freeaddrinfo(result)
                }
                pending.resume(returning: .finished(code: code))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout / .seconds(1)) {
                pending.resume(returning: .timedOut)
            }
        }
    }
}

/// 名前解決とタイマーのうち、先に来た方だけが resume する
private final class PendingContinuation: Sendable {
    private let continuation: Mutex<CheckedContinuation<DNSResolver.Outcome, Never>?>

    init(_ continuation: CheckedContinuation<DNSResolver.Outcome, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(returning outcome: DNSResolver.Outcome) {
        continuation.withLock { $0.take() }?.resume(returning: outcome)
    }
}
