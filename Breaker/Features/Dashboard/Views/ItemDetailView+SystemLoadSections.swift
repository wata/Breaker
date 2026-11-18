import AppKit
import Charts
import SwiftUI

extension ItemDetailView {
    /**
     負荷の詳細。主役は通知で、ここでは「どのアプリが・いつから」を指すことに絞る（利用者の判断）。
     汎用のプロセス一覧にはせず、今いちばん使っている数件と、原因のアプリがいつから全体を押し上げているかの1枚だけを見せる。
     Mac 全体の CPU はサイドバーの行とグラフの面にあるので、大きな数字では繰り返さない
     */
    struct SystemLoadSections: View {
        let load: SystemLoad
        let status: ItemStatus

        var body: some View {
            let finding = LoadCheck.finding(in: load, now: load.history.last?.date ?? .now)
            let highlight = status.isAbnormal ? status : nil
            let culprit = load.culprit
            let sinceDate = culprit.flatMap { LoadCheck.sinceDate(of: $0, in: load.history) }

            Section("Using the CPU") {
                ForEach(load.topConsumers, id: \.name) { consumer in
                    ConsumerRow(
                        consumer: consumer,
                        sinceDate: consumer.name == culprit ? sinceDate : nil,
                        highlight: consumer.name == culprit ? highlight : nil
                    )
                }
            }

            Section {
                LoadChart(load: load, culprit: culprit, sinceDate: sinceDate)
            } header: {
                Text("CPU History")
            } footer: {
                // 2行とも「正常」の節は CPU の原因を探す目の邪魔になるので、正常なときは1行の補足に畳む
                if load.isThermalAndMemoryNormal {
                    Text("Temperature and memory are normal.")
                        .font(.Base.regular)
                        .foregroundStyle(.secondary)
                }
            }

            if !load.isThermalAndMemoryNormal {
                MacSection(load: load, finding: finding, highlight: highlight)
            }
        }
    }

    /// 温度とメモリ。どちらかが正常でないときだけ行で見せる
    struct MacSection: View {
        let load: SystemLoad
        let finding: LoadCheck.Finding?
        let highlight: ItemStatus?

        var body: some View {
            Section("Mac") {
                MetricRow(
                    title: "Temperature",
                    value: load.thermalState.title,
                    highlight: finding == .thermalThrottling ? highlight : nil
                )

                MetricRow(
                    title: "Memory Pressure",
                    value: load.memoryPressure.title,
                    highlight: finding == .memoryShortage ? highlight : nil
                )
            }
        }
    }

    /// アプリのアイコンと名前、今の CPU。原因のアプリには、通知を読んだ人が次に知りたい「いつから」を添える
    struct ConsumerRow: View {
        let consumer: SystemLoad.Consumer
        let sinceDate: Date?
        let highlight: ItemStatus?

        var body: some View {
            LabeledContent {
                HStack(spacing: Spacing.micro) {
                    if let highlight {
                        StatusMark(status: highlight)
                    }

                    Text(SystemLoad.percentText(consumer.cpuPercent))
                        .foregroundStyle(highlight?.color ?? .secondary)
                        .monospacedDigit()
                }
            } label: {
                HStack(spacing: Spacing.tight) {
                    AppIcon(bundlePath: consumer.bundlePath)

                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text(consumer.name)

                        if let sinceDate {
                            Text(
                                "Since \(MonitoredItem.formatRunDate(sinceDate, now: .now))",
                                comment: "When the app started using a lot of CPU, e.g. Since Today 14:05"
                            )
                            .font(.Base.regular)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// アプリのアイコン。アプリに入っていないプロセスは歯車の記号にする
    struct AppIcon: View {
        let bundlePath: String?

        var body: some View {
            Group {
                if let bundlePath {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                        .resizable()
                } else {
                    Image(systemName: "gearshape")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Layout.appIconSize, height: Layout.appIconSize)
            .accessibilityHidden(true)
        }
    }

    /**
     直近24時間の CPU。全体を面で描き、原因のアプリがあれば、走り始めた時刻に縦線を引いてそこから先だけを線で重ねる。
     原因の無い区間まで線を描くと横軸に重なって軸に見えるので描かない。縦軸はデータに合わせ、低い負荷が下に潰れないようにする。
     面と線を同じ縦軸で比べられるよう、どちらも Mac 全体＝100 の割合で描く
     */
    struct LoadChart: View {
        let load: SystemLoad
        let culprit: String?
        let sinceDate: Date?

        var body: some View {
            let history = load.history
            if
                let lastDate = history.last?.date,
                history.count > 1
            {
                let total = String(localized: "Whole Mac", comment: "Chart legend: CPU of the whole Mac")
                Chart {
                    ForEach(history, id: \.date) { sample in
                        AreaMark(
                            x: .value("Date", sample.date),
                            y: .value("CPU", load.macPercent(of: sample.cpuPercent)),
                            series: .value("Series", total)
                        )
                        .foregroundStyle(by: .value("Series", total))
                        .accessibilityValue(SystemLoad.percentText(load.macPercent(of: sample.cpuPercent)))
                    }

                    if
                        let culprit,
                        let sinceDate
                    {
                        // 時刻は原因のアプリの行に「… から」と出ているので、線には文字を添えない
                        RuleMark(x: .value("Date", sinceDate))
                            .foregroundStyle(Color.LoadChart.highlight)
                            .lineStyle(StrokeStyle(lineWidth: Layout.timelineHairlineWidth))

                        ForEach(history.filter { $0.date >= sinceDate }, id: \.date) { sample in
                            LineMark(
                                x: .value("Date", sample.date),
                                y: .value("CPU", load.macPercent(of: sample.cpuPercent(of: culprit))),
                                series: .value("Series", culprit)
                            )
                            .foregroundStyle(by: .value("Series", culprit))
                            .lineStyle(StrokeStyle(lineWidth: Layout.chartLineWidth))
                            .accessibilityValue(SystemLoad.percentText(load.macPercent(of: sample.cpuPercent(of: culprit))))
                        }
                    }
                }
                .chartForegroundStyleScale(
                    domain: [total] + [culprit].compactMap { $0 },
                    range: [Color.LoadChart.total, Color.LoadChart.highlight]
                )
                .chartXScale(domain: lastDate.addingTimeInterval(-LoadHistory.retention)...lastDate)
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()

                        AxisValueLabel {
                            if let percent = value.as(Double.self) {
                                Text(SystemLoad.percentText(percent))
                            }
                        }
                    }
                }
                .frame(height: Layout.speedChartHeight)
                .padding(.vertical, Spacing.micro)
            } else {
                Text("CPU history appears here as checks accumulate.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension SystemLoad {
    /// 詳細に並べるアプリの数。原因を指すのに足り、プロセス一覧にはならない数
    static let listedConsumerCount = 5

    var topConsumers: [Consumer] {
        Array(consumers.prefix(Self.listedConsumerCount))
    }

    /// 熱で絞られておらず（fair までは絞らない）、メモリにも余裕がある
    var isThermalAndMemoryNormal: Bool {
        [.nominal, .fair].contains(thermalState) && memoryPressure == .normal
    }
}
