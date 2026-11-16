import Foundation

/**
 ネットワークの値の書式。詳細とサイドバーで同じ書き方にそろえるため、どれも `String` を返す。
 数値はロケールの書式（桁区切り・小数点）に従い、単位（Mbps・ms・dBm など）はどの言語でもそのまま使われる記号なので訳さない
 */
extension NetworkHealth {
    /// 値が無い・測っていないときに出す
    static let placeholder = "—"

    /// `146 Mbps`。10 Mbps 未満は整数に丸めると遅い回線の差が消える（0.4 と 0 など）ので、小数1桁まで出す
    static func speedText(bitsPerSecond: Double, locale: Locale = .current) -> String {
        speedText(megabitsPerSecond: bitsPerSecond / 1_000_000, locale: locale)
    }

    static func speedText(megabitsPerSecond: Double, locale: Locale = .current) -> String {
        "\(speedNumberText(megabitsPerSecond: megabitsPerSecond, locale: locale)) \(speedUnit)"
    }

    /// 詳細の大きな数字は、数字だけを大きくして単位を添えるので分けて出す
    static let speedUnit = "Mbps"

    static func speedNumberText(megabitsPerSecond: Double, locale: Locale = .current) -> String {
        let fraction = megabitsPerSecond < 10 ? 0...1 : 0...0
        return megabitsPerSecond.formatted(.number.precision(.fractionLength(fraction)).locale(locale))
    }

    /// `3.4 ms`・`18 ms`。10 ms 未満の差（ルーターまでの数 ms）は小数1桁で、それ以上は整数で見せる
    static func latencyText(milliseconds: Double, locale: Locale = .current) -> String {
        let fraction = milliseconds < 10 ? 1...1 : 0...0
        return "\(milliseconds.formatted(.number.precision(.fractionLength(fraction)).locale(locale))) ms"
    }

    /// `0% loss`。`rate` は 0〜1
    static func packetLossText(_ rate: Double, locale: Locale = .current) -> String {
        let percent = rate.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        return String(
            localized: LocalizedStringResource("\(percent) loss", comment: "Packet loss rate of pings, e.g. 0% loss"),
            language: locale
        )
    }

    /// 電波の強さ・雑音（`-52 dBm`）
    static func powerText(decibelMilliwatts: Int, locale: Locale = .current) -> String {
        "\(powerNumberText(decibelMilliwatts: decibelMilliwatts, locale: locale)) \(powerUnit)"
    }

    /// 詳細の Wi-Fi の大きな数字は、数字だけを大きくして単位を添えるので分けて出す
    static let powerUnit = "dBm"

    static func powerNumberText(decibelMilliwatts: Int, locale: Locale = .current) -> String {
        decibelMilliwatts.formatted(.number.locale(locale))
    }

    /// 信号と雑音の差（`42 dB`）
    static func signalToNoiseText(decibels: Int, locale: Locale = .current) -> String {
        "\(decibels.formatted(.number.locale(locale))) dB"
    }

    /// 応答性（`1,027 RPM`）
    static func responsivenessText(_ roundTripsPerMinute: Double, locale: Locale = .current) -> String {
        "\(roundTripsPerMinute.formatted(.number.precision(.fractionLength(0)).locale(locale))) RPM"
    }

    /// サイドバーの行の2行目に出す要約（`↓146 Mbps · Latency 18 ms`）。数字だけでは何の値か分からないので、遅延にはラベルを付ける。速度と外部への遅延のどちらも無ければ nil
    func summary(locale: Locale = .current) -> String? {
        let parts = [
            lastSpeedTest?.speed.map { "↓\(Self.speedText(bitsPerSecond: $0.downloadBitsPerSecond, locale: locale))" },
            internetPing?.averageMilliseconds.map { milliseconds in
                String(
                    localized: LocalizedStringResource(
                        "Latency \(Self.latencyText(milliseconds: milliseconds, locale: locale))",
                        comment: "Sidebar: average ping time to the internet after the download speed, e.g. Latency 13 ms"
                    ),
                    language: locale
                )
            },
        ]
        .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension NetworkHealth.PathStatus {
    var title: String {
        switch self {
        case .satisfied:
            String(localized: "Connected", comment: "Network path status: a network interface is usable")

        case .unsatisfied:
            String(localized: "Not connected", comment: "Network path status: no network interface is usable")

        case .requiresConnection:
            String(localized: "Connects on demand", comment: "Network path status: the network (such as an on-demand VPN) connects when used")
        }
    }
}

extension NetworkHealth.Interface {
    var systemImage: String {
        switch self {
        case .wifi:
            "wifi"

        case .wiredEthernet:
            "cable.connector.horizontal"

        case .cellular:
            "antenna.radiowaves.left.and.right"

        case .other, .none:
            "network"
        }
    }

    var title: String {
        switch self {
        case .wifi:
            "Wi-Fi"

        case .wiredEthernet:
            String(localized: "Ethernet", comment: "Network interface type: wired Ethernet")

        case .cellular:
            String(localized: "Cellular", comment: "Network interface type: cellular (such as iPhone tethering over a cellular network)")

        case .other:
            String(localized: "Other", comment: "Network interface type that is not Wi-Fi, Ethernet or cellular (such as a VPN)")

        case .none:
            String(localized: "None", comment: "Shown when there is nothing to show, e.g. no schedule trigger or no log output")
        }
    }
}

extension NetworkHealth.InternetAccess {
    var title: String {
        switch self {
        case .reachable:
            String(localized: "Reachable", comment: "Internet access: a page on the internet could be loaded")

        case .unreachable:
            String(localized: "Unreachable", comment: "Internet access: nothing on the internet could be loaded. The reason is shown separately")

        // 項目の理由と同じ文言にする
        case .captivePortal:
            String(localized: "Sign-in required", comment: "Reason of the network item when the network shows a sign-in page (such as hotel Wi-Fi)")
        }
    }
}

extension NetworkHealth.DNSLookup {
    func title(locale: Locale = .current) -> String {
        switch self {
        case .resolved(let milliseconds):
            NetworkHealth.latencyText(milliseconds: milliseconds, locale: locale)

        case .failed:
            String(
                localized: LocalizedStringResource("Lookup failed", comment: "DNS lookup result when the name couldn't be resolved. The reason is shown separately"),
                language: locale
            )
        }
    }
}

extension NetworkHealth.WiFiInfo {
    /// 電波の強さのバーの本数
    static let signalBarCount = 4
    /// バーが1本増える電波の強さの幅
    static let signalStepDecibels = 10

    /**
     電波の強さのバーの段数（1〜`signalBarCount`）。弱いと判定する値（`NetworkCheck.weakSignalThresholdDecibelMilliwatts`）未満を1本にし、
     判定とバーの見た目が食い違わないようにする。それより上は `signalStepDecibels` ごとに1本ずつ増やす（-50 dBm 以上で全部）
     */
    var signalLevel: Int {
        let thresholds = (0..<Self.signalBarCount - 1).map { NetworkCheck.weakSignalThresholdDecibelMilliwatts + $0 * Self.signalStepDecibels }
        return 1 + thresholds.filter { rssi >= $0 }.count
    }

    /// `5 GHz`。帯域が分からなければ nil
    func bandText(locale: Locale = .current) -> String? {
        let gigahertz: Double? = switch band {
        case .twoPointFourGigahertz: 2.4
        case .fiveGigahertz: 5
        case .sixGigahertz: 6
        case .unknown: nil
        }
        return gigahertz.map { "\($0.formatted(.number.locale(locale))) GHz" }
    }

    /// `36 (80 MHz)`。幅が分からなければチャンネルの番号だけ
    func channelText(locale: Locale = .current) -> String {
        let number = channelNumber.formatted(.number.grouping(.never).locale(locale))
        // 帯域は電波の大きな数字の下に出すので、ここでは幅だけを添える
        if let channelWidth {
            return String.parenthesized(number, "\(channelWidth.formatted(.number.locale(locale))) MHz", locale: locale)
        } else {
            return number
        }
    }

    /**
     `Wi-Fi 6 (802.11ax)`。規格の番号は利用者に馴染みが無いので、Wi-Fi Alliance の世代名を前に出す。
     802.11ax でも 6 GHz で使っていれば Wi-Fi 6E と呼ばれる。世代名の無い古い規格は番号だけ
     */
    func standardText(locale: Locale = .current) -> String? {
        guard let phyMode else {
            return nil
        }
        let generation: String? = switch phyMode {
        case "802.11be": "Wi-Fi 7"
        case "802.11ax": band == .sixGigahertz ? "Wi-Fi 6E" : "Wi-Fi 6"
        case "802.11ac": "Wi-Fi 5"
        case "802.11n": "Wi-Fi 4"
        default: nil
        }
        return generation.map { String.parenthesized($0, phyMode, locale: locale) } ?? phyMode
    }
}

extension NetworkHealth.PingResult {
    /// 1つも返ってこなかった ping。原因でなければ（インターネットには届いている）、ICMP を落とすだけのルーターとして穏やかに言う
    func unansweredText(isCause: Bool, locale: Locale = .current) -> String {
        if isCause {
            String(localized: LocalizedStringResource("No response", comment: "Value when no ping got a reply"), language: locale)
        } else {
            String(
                localized: LocalizedStringResource("No ping reply", comment: "Value for a router that drops pings although the internet can be reached. Kept short to fit under the route diagram"),
                language: locale
            )
        }
    }
}
