import Foundation

/**
 集めたネットワークの状態から、項目の状態を決める判定。`HealthCheck` と同じく副作用を持たず、測るのは呼び出し側。
 つながらない順（経路 → ルーター → インターネット → DNS）に確かめ、根に近い原因を1つだけ出す
 */
enum NetworkCheck {
    /// 外部 ping のロスがこれ以上なら要確認
    static let packetLossThreshold = 0.1
    /// 外部 ping の平均がこれを超えたら要確認
    static let highLatencyThresholdMilliseconds = 100.0
    /// これ未満の RSSI は、通信が途切れがちになる目安
    static let weakSignalThresholdDecibelMilliwatts = -70
    /// RSSI と雑音の差がこれ未満だと、電波が強くても速度が落ちる
    static let lowSignalToNoiseThresholdDecibels = 20

    /**
     見つけた問題。揺れ止め（続けて失敗したときだけ失敗にする）を呼び出し側でかけられるよう、
     状態にする前の形で返し、接続系の失敗かどうかを `isConnectionFailure` で見分けられるようにする
     */
    enum Finding: Hashable, Sendable {
        case offline
        case routerNotResponding(routerAddress: String)
        case internetUnreachable
        case dnsNotResponding
        case captivePortal
        case packetLoss
        case highLatency
        case weakWiFiSignal
        case speedTestFailed(reason: String)

        /// つながらない失敗。一時的な取りこぼしで通知しないよう、呼び出し側が揺れ止めをかける対象
        var isConnectionFailure: Bool {
            switch self {
            case .offline, .routerNotResponding, .internetUnreachable, .dnsNotResponding:
                true

            case .captivePortal, .packetLoss, .highLatency, .weakWiFiSignal, .speedTestFailed:
                false
            }
        }

        /**
         補足には毎回変わる値（遅延・RSSI など）を入れない。`AbnormalAlert` は補足を含む状態の変化で通知し直すため、
         同じ異常が続くだけで通知が繰り返されてしまう
         */
        var status: ItemStatus {
            switch self {
            case .offline:
                .failed(reason: String(localized: "Offline", comment: "Reason of the network item when no network interface is usable"))

            case .routerNotResponding(let routerAddress):
                .failed(
                    reason: String(localized: "Router not responding", comment: "Reason of the network item when the router doesn't answer and the internet can't be reached. The router's IP address is shown separately"),
                    note: routerAddress
                )

            case .internetUnreachable:
                .failed(reason: String(localized: "Can't reach the internet", comment: "Reason of the network item when the router answers but nothing on the internet does"))

            case .dnsNotResponding:
                .failed(reason: String(localized: "DNS not responding", comment: "Reason of the network item when name lookups fail although the internet answers pings"))

            case .captivePortal:
                .warning(reason: String(localized: "Sign-in required", comment: "Reason of the network item when the network shows a sign-in page (such as hotel Wi-Fi)"))

            case .packetLoss:
                .warning(reason: String(localized: "Packet loss", comment: "Reason of the network item when some pings to the internet are lost"))

            case .highLatency:
                .warning(reason: String(localized: "High latency", comment: "Reason of the network item when pings to the internet take long"))

            case .weakWiFiSignal:
                .warning(reason: String(localized: "Weak Wi-Fi signal", comment: "Reason of the network item when the Wi-Fi signal is weak or noisy"))

            case .speedTestFailed(let reason):
                .warning(
                    reason: String(localized: "Speed test failed", comment: "Reason of the network item when the last speed test failed. The failure reason is shown separately"),
                    note: reason
                )
            }
        }
    }

    /// 揺れ止めをかけない状態。実際の項目は `NetworkCheckHistory` を通すので、これを使うのは見本と判定のテスト
    static func status(of health: NetworkHealth) -> ItemStatus {
        finding(in: health)?.status ?? .ok
    }

    /**
     上から順に確かめ、最初に見つかった問題を返す。
     速度の計測中は計測が回線を飽和させ、ping と到達確認が悪化するので、それらから出す問題（ルーター・インターネット・ロス・遅延）は確かめない
     */
    static func finding(in health: NetworkHealth) -> Finding? {
        // requiresConnection は使おうとすればつながる経路なので、オフラインにはせず以降の確認に任せる
        if health.pathStatus == .unsatisfied {
            return .offline
        }
        let internetReplied = (health.internetPing?.receivedCount ?? 0) > 0
        if
            !health.isTestingSpeed,
            case .unreachable = health.internetAccess
        {
            /**
             ICMP を落とすルーターもあるので、ルーターの無応答は到達もできないときだけ原因にする。
             ルーターのアドレスが無い経路（IPv6 だけ・VPN だけ）は確かめる先が無いので、インターネットの側で判定する
             */
            if
                let routerAddress = health.routerAddress,
                (health.routerPing?.receivedCount ?? 0) == 0
            {
                return .routerNotResponding(routerAddress: routerAddress)
            }
            if !internetReplied {
                return .internetUnreachable
            }
        }
        if
            case .failed = health.dnsLookup,
            internetReplied
        {
            return .dnsNotResponding
        }
        if health.internetAccess == .captivePortal {
            return .captivePortal
        }
        // 外部への ICMP を落とすネットワークもあるので、1つも返らなくても到達できていれば、ロスと遅延は見ない
        if
            !health.isTestingSpeed,
            let ping = health.internetPing,
            ping.receivedCount > 0 || health.internetAccess != .reachable
        {
            // ロスがあると届いた分だけの平均になり遅延が当てにならないので、ロスを先に出す
            if ping.lossRate >= packetLossThreshold {
                return .packetLoss
            }
            if
                let average = ping.averageMilliseconds,
                average > highLatencyThresholdMilliseconds
            {
                return .highLatency
            }
        }
        if
            let wifi = health.wifi,
            isWeak(rssi: wifi.rssi) || isLow(signalToNoise: wifi.signalToNoise)
        {
            return .weakWiFiSignal
        }
        if case .failed(let reason) = health.lastSpeedTest?.outcome {
            return .speedTestFailed(reason: reason)
        }
        return nil
    }

    static func isWeak(rssi: Int) -> Bool {
        rssi < weakSignalThresholdDecibelMilliwatts
    }

    static func isLow(signalToNoise: Int) -> Bool {
        signalToNoise < lowSignalToNoiseThresholdDecibels
    }
}

extension NetworkHealth {
    /**
     速度を測ってよいか。揺れ止め前の判定で決め、1回の接続の失敗でも回線は不安定なので測らない。
     スケジューラと詳細のツールバーの「今すぐ計測」で同じ基準にする
     */
    func isOnline(finding: NetworkCheck.Finding?) -> Bool {
        pathStatus != .unsatisfied && !(finding?.isConnectionFailure ?? false)
    }

    var isOnline: Bool {
        isOnline(finding: NetworkCheck.finding(in: self))
    }
}
