import Charts
import SwiftUI

extension ItemDetailView {
    /**
     ネットワークの詳細。上に図（経路図・速度の大きな数字と推移・Wi-Fi の電波）を置いて状態を一目で見せ、細かい値は下の行に残す。
     項目の状態を決めた問題（`NetworkCheck.finding`）の原因の値だけを目立たせ、どの値が悪いのかを指す。
     色と記号は項目の状態のものを使う。接続の失敗は1回目は「確認中」の要確認にとどめるので、判定し直した問題の色ではヘッダーと食い違う
     */
    struct NetworkSections: View {
        let health: NetworkHealth
        let status: ItemStatus
        let speedTestScheduler: SpeedTestScheduler

        var body: some View {
            let cause = Cause(finding: NetworkCheck.finding(in: health), status: status)

            Section {
                RouteDiagram(stages: RouteStage.stages(of: health, cause: cause))
            }

            /**
             異常なときの前回の速度は今の回線を表さず、大きな数字が原因より先に目に入ってしまうので、値は残したまま退かせる。
             計測の失敗が原因なら、速度の節が原因なので退かせない
             */
            let isStale = status.isAbnormal && cause.speedTestStatus == nil

            SpeedSection(scheduler: speedTestScheduler, cause: cause, isStale: isStale)

            Section("Speed History") {
                // 「直近7日」が古びないよう、分が変わるたびに描き直す
                TimelineView(.everyMinute) { context in
                    SpeedChart(records: speedTestScheduler.recentHistory(now: context.date), now: context.date)
                }
                .opacity(isStale ? Opacity.stale : 1)
            }

            if let wifi = health.wifi {
                WiFiSection(wifi: wifi, cause: cause)
            }

            // オフラインでは確かめていないので「—」だけの行が並ぶ。切れていることは経路図とヘッダーで分かる
            if health.pathStatus != .unsatisfied {
                ConnectionSection(health: health, cause: cause)

                PacketLossSection(routerPing: health.routerPing, internetPing: health.internetPing, cause: cause)
            }
        }
    }

    /// 項目の状態を決めた問題と、そのときの項目の状態。行は自分の値が原因のときだけ状態を受け取って目立たせる
    struct Cause: Equatable {
        let finding: NetworkCheck.Finding?
        let status: ItemStatus

        func highlight(for findings: [NetworkCheck.Finding]) -> ItemStatus? {
            if
                let finding,
                findings.contains(finding),
                status.isAbnormal
            {
                status
            } else {
                nil
            }
        }

        /// ルーターの無応答はアドレスを関連値に持つので、種類だけで見る
        var routerStatus: ItemStatus? {
            if
                case .routerNotResponding = finding,
                status.isAbnormal
            {
                status
            } else {
                nil
            }
        }

        /// 計測の失敗は理由を関連値に持つので、種類だけで見る。ほかの原因で要確認のときに、計測の失敗の行まで原因に見せない
        var speedTestStatus: ItemStatus? {
            if
                case .speedTestFailed = finding,
                status.isAbnormal
            {
                status
            } else {
                nil
            }
        }
    }

    /// 経路図に出ない値（アドレス・失敗の理由）。接続の状態・種類・遅延は経路図にあるので行にしない
    struct ConnectionSection: View {
        let health: NetworkHealth
        let cause: Cause

        var body: some View {
            Section("Connection") {
                MetricRow(
                    title: "Router",
                    value: health.routerAddress ?? NetworkHealth.placeholder,
                    highlight: cause.routerStatus
                )

                MetricRow(
                    title: "DNS Servers",
                    value: health.dnsServers.isEmpty ? NetworkHealth.placeholder : health.dnsServers.joined(separator: ", ")
                )

                MetricRow(
                    title: "DNS Lookup",
                    value: health.dnsLookup?.title() ?? NetworkHealth.placeholder,
                    note: health.dnsLookup?.failureReason,
                    highlight: cause.highlight(for: [.dnsNotResponding])
                )

                MetricRow(
                    title: "Internet",
                    value: health.internetAccess?.title ?? NetworkHealth.placeholder,
                    note: health.internetAccess?.failureReason,
                    highlight: cause.highlight(for: [.internetUnreachable, .captivePortal])
                )
            }
        }
    }

    /**
     ルーターと外部への ping のロス率。平均の遅延は経路図に出す。ICMP を落とすルーターは多く、インターネットに届いていれば問題ではないので、
     その場合は原因の色を付けずに「ping に応答しません」と添えるだけにする
     */
    struct PacketLossSection: View {
        let routerPing: NetworkHealth.PingResult?
        let internetPing: NetworkHealth.PingResult?
        let cause: Cause

        var body: some View {
            Section("Packet Loss") {
                if
                    let routerPing,
                    routerPing.receivedCount == 0
                {
                    MetricRow(
                        title: "Router",
                        value: routerPing.unansweredText(isCause: cause.routerStatus != nil),
                        highlight: cause.routerStatus
                    )
                } else {
                    MetricRow(title: "Router", value: routerPing.map { NetworkHealth.packetLossText($0.lossRate) } ?? NetworkHealth.placeholder)
                }

                MetricRow(
                    title: "Internet (\(internetPing?.destination ?? NetworkSource.internetPingDestinations.joined(separator: ", ")))",
                    value: internetPing.map { NetworkHealth.packetLossText($0.lossRate) } ?? NetworkHealth.placeholder,
                    highlight: cause.highlight(for: [.packetLoss])
                )
            }
        }
    }

    /**
     速度はスケジューラの値を直接見る。項目の `NetworkHealth.lastSpeedTest` は次のチェックまで古いままなので、
     計測を終えた直後や計測中の表示がずれる。
     計測を始める「今すぐ計測」は、ほかの項目の「今すぐ実行」と同じくツールバーに置く（`MeasureButton`）。ここでは計測中であることだけを出す
     */
    struct SpeedSection: View {
        let scheduler: SpeedTestScheduler
        let cause: Cause
        let isStale: Bool

        var body: some View {
            Section("Speed") {
                if let record = scheduler.lastRecord {
                    switch record.outcome {
                    case .succeeded(let speed):
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.spacious) {
                            SpeedFigure(direction: .download, speed: speed, isStale: isStale)

                            SpeedFigure(direction: .upload, speed: speed, isStale: isStale)

                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, Spacing.micro)

                        if let responsiveness = speed.responsiveness {
                            MetricRow(title: "Responsiveness", value: NetworkHealth.responsivenessText(responsiveness))
                        }

                    case .failed(let reason):
                        MetricRow(
                            title: "Last Test",
                            value: String(localized: "Failed", comment: "Status of an item whose last run failed"),
                            note: reason,
                            highlight: cause.speedTestStatus
                        )
                    }

                    // 「20 分前」が古びないよう、分が変わるたびに書き直す
                    TimelineView(.everyMinute) { context in
                        MetricRow(title: "Measured", value: MonitoredItem.relativeDateText(record.date, now: context.date))
                    }
                } else {
                    MetricRow(
                        title: "Last Test",
                        value: String(localized: "Not measured yet", comment: "Speed section when no speed test has run")
                    )
                }

                if scheduler.isMeasuring {
                    HStack(spacing: Spacing.tight) {
                        ProgressView()
                            .controlSize(.small)

                        Text("Measuring…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 速度の向き。大きな数字の矢印とグラフの線を同じ色にして、どちらの線がどちらの値かを示す
    enum SpeedDirection: CaseIterable {
        case download
        case upload

        var title: String {
            switch self {
            case .download:
                String(localized: "Download", comment: "Row label in the network detail: download speed")

            case .upload:
                String(localized: "Upload", comment: "Row label in the network detail: upload speed")
            }
        }

        var systemImage: String {
            switch self {
            case .download:
                "arrow.down"

            case .upload:
                "arrow.up"
            }
        }

        var color: Color {
            switch self {
            case .download:
                .Speed.download

            case .upload:
                .Speed.upload
            }
        }

        func megabitsPerSecond(of speed: SpeedTestRecord.Speed) -> Double {
            switch self {
            case .download:
                speed.downloadBitsPerSecond / 1_000_000

            case .upload:
                speed.uploadBitsPerSecond / 1_000_000
            }
        }
    }

    /// `↓ 146 Mbps`。数字だけを大きくし、単位は本文の大きさで添える。今の回線を表さない値は二次色にする
    struct SpeedFigure: View {
        let direction: SpeedDirection
        let speed: SpeedTestRecord.Speed
        let isStale: Bool

        var body: some View {
            let megabitsPerSecond = direction.megabitsPerSecond(of: speed)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(direction.title)
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: Spacing.micro) {
                    Image(systemName: direction.systemImage)
                        .font(.Display.symbol)
                        .foregroundStyle(isStale ? .secondary : direction.color)

                    Text(NetworkHealth.speedNumberText(megabitsPerSecond: megabitsPerSecond))
                        .font(.Display.value)
                        .foregroundStyle(isStale ? .secondary : .primary)
                        .textSelection(.enabled)

                    Text(verbatim: NetworkHealth.speedUnit)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(direction.title)
            .accessibilityValue(NetworkHealth.speedText(megabitsPerSecond: megabitsPerSecond))
        }
    }

    /// 直近の速度の推移。下りと上りを色と線の形（上りは破線）の両方で見分けられるようにする
    struct SpeedChart: View {
        /// 直近の成功した計測（`SpeedTestScheduler.recentHistory(now:)`）
        let records: [SpeedTestRecord]
        let now: Date

        @State private var hoverDate: Date?

        var body: some View {
            if records.count <= 1 {
                Text("Speed history appears here as measurements accumulate.")
                    .foregroundStyle(.secondary)
            } else {
                let hovered = hoverDate.flatMap { records.nearest(to: $0, by: \.date) }
                Chart {
                    ForEach(SpeedDirection.allCases, id: \.self) { direction in
                        ForEach(records, id: \.date) { record in
                            if let speed = record.speed {
                                LineMark(
                                    x: .value("Date", record.date),
                                    y: .value(NetworkHealth.speedUnit, direction.megabitsPerSecond(of: speed)),
                                    series: .value("Direction", direction.title)
                                )
                                .foregroundStyle(by: .value("Direction", direction.title))
                                .lineStyle(by: .value("Direction", direction.title))
                            }
                        }
                    }

                    if
                        let hovered,
                        let speed = hovered.speed
                    {
                        RuleMark(x: .value("Date", hovered.date))
                            .foregroundStyle(Color.secondary)
                            .lineStyle(StrokeStyle(lineWidth: Layout.timelineHairlineWidth))
                            .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                                ChartTooltip(
                                    title: MonitoredItem.formatRunDate(hovered.date, now: now),
                                    rows: SpeedDirection.allCases.map { direction in
                                        ChartTooltip.Row(
                                            title: direction.title,
                                            value: NetworkHealth.speedText(megabitsPerSecond: direction.megabitsPerSecond(of: speed)),
                                            color: direction.color
                                        )
                                    }
                                )
                            }
                    }
                }
                .chartForegroundStyleScale(
                    domain: SpeedDirection.allCases.map(\.title),
                    range: SpeedDirection.allCases.map(\.color)
                )
                // 凡例にも線の形が出るよう、上りの破線は系列の線の形として渡す
                .chartLineStyleScale(
                    domain: SpeedDirection.allCases.map(\.title),
                    range: SpeedDirection.allCases.map { StrokeStyle(lineWidth: Layout.chartLineWidth, dash: $0 == .upload ? Layout.chartLineDash : []) }
                )
                // 2本の線を読むのに縦の補助線は要らないので、日付の目盛りだけにする
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                    }
                }
                .chartXScale(domain: now.addingTimeInterval(-SpeedTestScheduler.chartPeriod)...now)
                .chartYAxisLabel(NetworkHealth.speedUnit)
                .chartHoverDate($hoverDate)
                .frame(height: Layout.speedChartHeight)
                .padding(.vertical, Spacing.micro)
            }
        }
    }

    /// SSID は位置情報の許可が無いと読めない。読めないときは「—」の行で場所を取らず、行ごと出さない
    struct WiFiSection: View {
        let wifi: NetworkHealth.WiFiInfo
        let cause: Cause

        var body: some View {
            let weakSignal = cause.highlight(for: [.weakWiFiSignal])
            Section("Wi-Fi") {
                SignalFigure(wifi: wifi, highlight: NetworkCheck.isWeak(rssi: wifi.rssi) ? weakSignal : nil)

                if let ssid = wifi.ssid {
                    MetricRow(title: "Network Name", value: ssid)
                }

                MetricRow(title: "Channel", value: wifi.channelText())

                MetricRow(title: "Noise", value: NetworkHealth.powerText(decibelMilliwatts: wifi.noise))

                MetricRow(
                    title: "Signal-to-Noise",
                    value: NetworkHealth.signalToNoiseText(decibels: wifi.signalToNoise),
                    highlight: NetworkCheck.isLow(signalToNoise: wifi.signalToNoise) ? weakSignal : nil
                )

                MetricRow(title: "Transmit Rate", value: NetworkHealth.speedText(megabitsPerSecond: wifi.transmitRate))
            }
        }
    }

    /// 電波の強さのバーと dBm を大きく出し、帯域と規格を下に添える。弱い電波が原因なら、色だけに頼らず記号も添える
    struct SignalFigure: View {
        let wifi: NetworkHealth.WiFiInfo
        let highlight: ItemStatus?

        var body: some View {
            let details = [wifi.bandText(), wifi.standardText()].compactMap { $0 }
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text("Signal")
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: Spacing.micro) {
                    Image(
                        systemName: "wifi",
                        variableValue: Double(wifi.signalLevel) / Double(NetworkHealth.WiFiInfo.signalBarCount)
                    )
                    .font(.Display.symbol)
                    .foregroundStyle(highlight?.color ?? .primary)

                    Text(NetworkHealth.powerNumberText(decibelMilliwatts: wifi.rssi))
                        .font(.Display.value)
                        .foregroundStyle(highlight?.color ?? .primary)
                        .textSelection(.enabled)

                    Text(verbatim: NetworkHealth.powerUnit)
                        .foregroundStyle(.secondary)

                    if let highlight {
                        StatusMark(status: highlight)
                    }
                }

                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, Spacing.micro)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Signal"))
            .accessibilityValue(
                ([NetworkHealth.powerText(decibelMilliwatts: wifi.rssi), highlight?.title].compactMap { $0 } + details).formatted(.list(type: .and, width: .narrow))
            )
        }
    }

    /// 値は右に寄せ、補足（失敗の理由など）は値の下に小さく出す。原因の値は色だけに頼らず記号も添える
    struct MetricRow: View {
        let title: LocalizedStringKey
        let value: String
        var note: String?
        var highlight: ItemStatus?

        var body: some View {
            LabeledContent {
                VStack(alignment: .trailing, spacing: Spacing.hairline) {
                    HStack(spacing: Spacing.micro) {
                        if let highlight {
                            StatusMark(status: highlight)
                        }

                        Text(value)
                            .foregroundStyle(highlight?.color ?? .secondary)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }

                    if let note {
                        Text(note)
                            .font(.Base.regular)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            } label: {
                Text(title)
            }
        }
    }

    /// 色だけでは見分けにくいので、ヘッダーやサイドバーと同じ状態の記号を添える
    struct StatusMark: View {
        let status: ItemStatus

        var body: some View {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.color)
                .accessibilityLabel(status.title)
        }
    }
}
