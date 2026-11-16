import SwiftUI

extension ItemDetailView {
    /**
     今を挟んだ一定の幅に、予定の時刻・前回・今を並べたもの。幅は予定の間隔に合わせて15分〜1年から選び、
     予定の点がいくつか（`minimumRuns` 以上、重ならない `runLimit` 未満）並んで、ジョブの刻みが読み取れるようにする。
     今より前も少し見せ、前回がどうだったか、予定どおりに走ったか、次がどれくらい先かを同じ線の上で比べられるようにする
     */
    struct RunTimeline: Equatable {
        /// 短い順に並べ、短いものから順に試す
        enum Scale: CaseIterable, Comparable {
            case quarterHour
            case hour
            case sixHours
            case day
            case week
            case month
            case year

            /// 今より前と後に見せる長さ。次回を主に見せつつ、前回を振り返れるよう前も4分の1ほど取る
            var span: (before: TimeInterval, after: TimeInterval) {
                switch self {
                case .quarterHour:
                    (4 * 60, 11 * 60)

                case .hour:
                    (15 * 60, 45 * 60)

                case .sixHours:
                    (90 * 60, 270 * 60)

                case .day:
                    (6 * 3600, 18 * 3600)

                case .week:
                    (2 * 86400, 6 * 86400)

                case .month:
                    (4 * 86400, 26 * 86400)

                case .year:
                    (60 * 86400, 305 * 86400)
                }
            }

            func interval(around now: Date) -> DateInterval {
                DateInterval(start: now.addingTimeInterval(-span.before), end: now.addingTimeInterval(span.after))
            }

            /// 常駐・予定の無いジョブの幅。これから先に描くものが無いので、同じ長さのまま「今」を右端寄り（`pastShare`）に置き、過去を広く見せる
            func pastInterval(endingAt now: Date) -> DateInterval {
                let duration = span.before + span.after
                return DateInterval(start: now.addingTimeInterval(-duration * Self.pastShare), end: now.addingTimeInterval(duration * (1 - Self.pastShare)))
            }

            /// 常駐・予定の無いジョブの幅のうち、今より前に充てる割合
            static let pastShare = 0.85

            /// 目盛りの間隔。幅の中に3〜8本ほど入り、見出しが重ならないもの
            var tickStep: DateComponents {
                switch self {
                case .quarterHour:
                    DateComponents(minute: 5)

                case .hour:
                    DateComponents(minute: 15)

                case .sixHours:
                    DateComponents(hour: 1)

                case .day:
                    DateComponents(hour: 6)

                case .week:
                    DateComponents(day: 1)

                case .month:
                    DateComponents(day: 7)

                case .year:
                    DateComponents(month: 1)
                }
            }

            /**
             曜日と月はその区切りから右へ書き、次の区切りまでがその日・その月だと読めるようにする（カレンダーと同じ）。
             時刻と日付はその瞬間を指すので、目盛りの真下に置く
             */
            var labelAlignment: Alignment {
                switch self {
                case .week, .year:
                    .leading

                case .quarterHour, .hour, .sixHours, .day, .month:
                    .center
                }
            }

            /// 最初の目盛りを揃える区切り（時・日・週・月の初め）
            var tickAnchor: Calendar.Component {
                switch self {
                case .quarterHour, .hour, .sixHours:
                    .hour

                case .day, .week:
                    .day

                case .month:
                    .weekOfYear

                case .year:
                    .month
                }
            }
        }

        /// これより多い予定は点が重なって読めないので、もっと短い幅にする
        static let runLimit = 30
        /// 刻みが読み取れるよう、できればこの数以上の予定が並ぶ幅にする（毎日のジョブなら1週間、毎月なら1年）
        static let minimumRuns = 3

        /// 線の端からこの割合の内側にだけ見出しを置く（左寄せの曜日・月も、中央に置く時刻・日付も切れないように。左寄せは左端では切れない）
        private static let labelMargin: CGFloat = 0.04
        /// 常駐ジョブの起動・予定の無いジョブの前回を置ける、今からいちばん遠い位置（今より前の部分の長さに対する割合）。左端に寄りすぎると端で切れて見える
        private static let anchorPlacementLimit = 0.95

        let scale: Scale
        let interval: DateInterval
        let now: Date
        /// 予定の印。次回と走らなかった予定は別の印で描くので含めない
        let runs: [Date]
        /**
         実行を見た最後の時刻（範囲の外でも持つ）。これまでの予定のうち、これ以前のものだけを走った予定として塗る。
         これより後の過ぎた予定は走っていない（または前回が分からない）ので、塗らない
         */
        let ranUntil: Date?
        let nextRun: Date?
        let lastRun: Date?
        /// 前回の印の記号と色。成否を言えない（動いている・未確認）ときは nil で、無地の印にする
        let lastRunStatus: ItemStatus?
        /// 走らなかった予定。項目の状態が「予定どおり実行されていません」のときだけ、その予定に状態の色の輪を描く
        let missedRun: Date?
        /// 目盛りの位置（`Scale.tickStep` ごと）
        let ticks: [Date]
        /// 見出しを添える目盛り。右端で切れてしまうものを除く
        let labeledTicks: [Date]
        /// 動き続けている常駐ジョブ（KeepAlive）。起動した時刻（分からなければ見えている範囲の初め）から今までを実行中の色の帯で塗る
        let isAlwaysRunning: Bool
        /// 常駐ジョブのプロセスが起動した時刻。帯をここから塗り、起動の印と見出しを置く。見えている範囲より前なら、帯は左端から塗る
        let runningSince: Date?
        /**
         線の下に添える凡例。常駐ジョブの緑の帯が何を表すかを言う。帯だけだと何の色か読み取れなかったので添える（利用者の判断）。
         決まった予定の無いジョブのきっかけは、右上の記号とジョブの節のスケジュールの行が言うので添えない（利用者の判断）
         */
        let note: String?

        /**
         止めているジョブには作らない。走らないので線に載せる予定が無く、止めていることは概要が言う（利用者の判断）。
         ほかのジョブには必ず作る。決まった予定の無いジョブ（ログイン時・ファイルの監視だけ）は前回だけを載せる。
         `nextRun` は概要の次回と同じもの
         */
        init?(job: MonitoredItem.LaunchdJob, status: ItemStatus, nextRun: Date?, now: Date, calendar: Calendar = .current) {
            guard !status.isInactive else { return nil }

            let isAlwaysRunning = job.isAlwaysRunning

            // 常駐ジョブの前回はログを書いた時刻で、起動した時刻ではないので使わない
            let runningSince = job.runningSince
            let window = isAlwaysRunning
                ? Self.pastWindow(anchor: runningSince, now: now)
                : Self.window(of: job, nextRun: nextRun, now: now, calendar: calendar)
            let (scale, interval, runs) = (window.scale, window.interval, window.runs)

            // 走らなかった予定の日時は状態の補足にある。補足と同じ書き方になる予定を探す
            let missedRun = status.isFailed ? runs.first { $0 < now && status == HealthCheck.missedRunStatus($0) } : nil

            self.scale = scale
            self.interval = interval
            self.now = now
            let nextRun = isAlwaysRunning ? nil : nextRun.flatMap { interval.contains($0) ? $0 : nil }
            self.runs = runs.filter { $0 != nextRun && $0 != missedRun }
            ranUntil = job.lastRun
            self.nextRun = nextRun
            lastRun = isAlwaysRunning ? nil : job.lastRun.flatMap { interval.contains($0) ? $0 : nil }
            self.isAlwaysRunning = isAlwaysRunning
            self.runningSince = runningSince
            // 緑の帯が何かを言う。いつからかは線の上の起動の印と見出しが言う（利用者の判断）
            note = isAlwaysRunning ? String(localized: "Always running (KeepAlive)") : nil
            /**
             走らなかったことが失敗の理由なら、前回の実行そのものは失敗していない。前回の印は終了コードで決め、失敗は走らなかった予定の輪に任せる。
             ほかの失敗・要確認（終了コード・ログのエラー）は前回の実行の結果なので、項目の状態をそのまま使う
             */
            lastRunStatus = switch status {
            case .failed where missedRun != nil:
                job.service?.lastExit.isFailure == true ? status : .ok

            case .ok, .failed, .warning:
                status

            case .running, .inactive, .unknown:
                nil
            }
            self.missedRun = missedRun
            let ticks = Self.ticks(in: interval, scale: scale, calendar: calendar)
            self.ticks = ticks
            // 中央に置く見出しは、左端に近いと半分がはみ出して切れる
            let leadingMargin = scale.labelAlignment == .leading ? 0 : Self.labelMargin
            labeledTicks = ticks.filter { tick in
                (leadingMargin...(1 - Self.labelMargin)).contains(CGFloat(tick.timeIntervalSince(interval.start) / interval.duration))
            }
        }

        /// 止めているジョブは走らないので次回が無い（概要の次回と同じ決め方）
        static func nextRun(of job: MonitoredItem.LaunchdJob, status: ItemStatus, now: Date) -> Date? {
            status.isInactive ? nil : job.schedule.nextRun(after: now, lastRun: job.lastRun)
        }

        /// 詳細のカードと概要の文で、同じ次回から作る
        init?(job: MonitoredItem.LaunchdJob, status: ItemStatus, now: Date) {
            self.init(job: job, status: status, nextRun: Self.nextRun(of: job, status: status, now: now), now: now)
        }

        /// 選んだ幅と、その中の予定
        struct Window {
            let scale: Scale
            let interval: DateInterval
            let runs: [Date]
        }

        /**
         予定のあるジョブは、短い幅から順に、次回と前回が入り予定の点が重ならない幅を探す。点が `minimumRuns` 個以上並ぶ幅を先に選ぶ。
         前回が遠すぎて（スリープしていた間など）どの幅にも入らなければ、次回だけで決める。
         次回の無いジョブ（決まった予定が無い）は、点で刻みを見せられず、これから先に描くものも無いので、前回で決める過去寄りの幅にする
         */
        static func window(of job: MonitoredItem.LaunchdJob, nextRun: Date?, now: Date, calendar: Calendar) -> Window {
            let candidates = Scale.allCases.map { scale in
                let interval = scale.interval(around: now)
                return Window(scale: scale, interval: interval, runs: job.schedule.runs(in: interval, lastRun: job.lastRun, limit: runLimit, calendar: calendar))
            }
            .filter { $0.runs.count < runLimit }
            let fitting = { (dates: [Date]) in
                dates.isEmpty ? [] : candidates.filter { candidate in dates.allSatisfy { candidate.interval.contains($0) } }
            }
            let both = fitting([nextRun, job.lastRun].compactMap { $0 })
            let nextOnly = fitting([nextRun].compactMap { $0 })
            // 前回だけで幅を決めると予定の刻みが見えないので、次回があるときだけ予定で幅を決める
            let scheduled = nextRun == nil ? nil : both.first { $0.runs.count >= minimumRuns }
                ?? both.first
                ?? nextOnly.first { $0.runs.count >= minimumRuns }
                ?? nextOnly.first
            return scheduled ?? pastWindow(anchor: job.lastRun, now: now)
        }

        /**
         これから先に描くものの無いジョブの、「今」を右端寄りに置いた幅。常駐ジョブは起動した時刻、予定の無いジョブは前回（`anchor`）が
         入る最も短い幅にする。どの幅にも入らないほど前なら1年の幅にする（常駐の帯は左端から塗る）。`anchor` が分からなければ1日。
         今に近くても見出しは「今」の見出しを避けて左へずらすので、離すための下限は設けない（設けると30時間前が1年の幅まで飛んだ）
         */
        static func pastWindow(anchor: Date?, now: Date) -> Window {
            let scale = anchor.map { anchor in
                Scale.allCases.first { scale in
                    now.timeIntervalSince(anchor) <= now.timeIntervalSince(scale.pastInterval(endingAt: now).start) * anchorPlacementLimit
                }
                    ?? .year
            }
                ?? .day
            return Window(scale: scale, interval: scale.pastInterval(endingAt: now), runs: [])
        }

        /**
         起動の見出し。線の範囲より前（1年の幅でも入らないほど前）に起動していれば、何年前かを取り違えないよう年を付けた日付だけにする
         */
        var startLabel: String? {
            runningSince.map { since in
                let date = since >= interval.start
                    ? MonitoredItem.formatRunDate(since, now: now)
                    : since.formatted(.dateTime.year().month(.defaultDigits).day())
                return String(
                    localized: "Started \(date)",
                    comment: "Label above the start of the green band on the run timeline of a launchd job that launchd keeps running, e.g. Started Yesterday 6:05 PM"
                )
            }
        }

        /// 線の左端を 0、右端を 1 とした位置
        func fraction(of date: Date) -> CGFloat {
            CGFloat(date.timeIntervalSince(interval.start) / interval.duration)
        }

        /**
         目盛りは壁時計の区切り（5分・15分・毎時・6時間ごと、日・週・月の初め）に置く。
         時・分を経過時間で足すと、夏時間の切り替わる日に 7時・13時 のような半端な時刻にずれるので、時・分の刻みは暦で合う時刻を探す
         */
        static func ticks(in interval: DateInterval, scale: Scale, calendar: Calendar) -> [Date] {
            let first = calendar.dateInterval(of: scale.tickAnchor, for: interval.start)?.start ?? interval.start
            let step = scale.tickStep
            // 正時から1時間ずつ進めると、夏時間の日も正時に乗る。その中で壁時計の時・分が刻みに合うものだけを残す
            let ticks: [Date] = if let minutes = step.minute ?? step.hour.map({ $0 * 60 }) {
                Array(sequence(first: first) { calendar.date(byAdding: .hour, value: 1, to: $0) }.prefix { $0 <= interval.end })
                    .flatMap { hour in stride(from: 0, to: 60, by: min(minutes, 60)).compactMap { calendar.date(byAdding: .minute, value: $0, to: hour) } }
                    .filter { (calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0)) % minutes == 0 }
            } else {
                Array(sequence(first: first) { calendar.date(byAdding: step, to: $0) }.prefix { $0 <= interval.end })
            }
            return ticks.filter { $0 > interval.start && $0 <= interval.end }
        }

        func tickLabel(_ date: Date, locale: Locale = .current) -> String {
            let style = Date.FormatStyle(locale: locale)
            return switch scale {
            case .quarterHour, .hour:
                date.formatted(style.hour().minute())

            case .sixHours, .day:
                date.formatted(style.hour())

            case .week:
                date.formatted(style.weekday(.abbreviated))

            case .month:
                date.formatted(style.month(.defaultDigits).day())

            case .year:
                date.formatted(style.month(.abbreviated))
            }
        }


        /// 読み上げの値。表示している範囲と前回・次回の文に、走らなかった予定の理由・起動・凡例を添える
        func accessibilityValue(status: ItemStatus) -> String {
            [
                (interval.start..<interval.end).formatted(.interval.month().day().hour().minute()),
                MonitoredItem.runSummary(lastRun: lastRun, nextRun: nextRun, lastRunStyle: .absolute, now: now),
                missedRun.flatMap { _ in status.fullReason },
                startLabel,
                note,
            ]
            .compactMap { $0 }
            .formatted(.list(type: .and, width: .narrow))
        }
    }

    /**
     タイムラインを描く。上に「今」（常駐ジョブは「起動」も）の見出し、中に軌道と印、下に目盛りの見出しと凡例を置く。
     色を持たせるのは、次回（アクセント色）と、前回の結果・走らなかった予定（状態の色）だけにし、ほかの予定は退かせる。
     動きは次回の印の呼吸だけにし、Reduce Motion では止める
     */
    struct TimelineStrip: View {
        let timeline: RunTimeline
        let status: ItemStatus

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        /// 「今」と「起動」の見出しを両端で切らず、重ねずに置くため、幅を測っておく
        @State private var nowLabelWidth: CGFloat = 0
        @State private var startLabelWidth: CGFloat = 0

        var body: some View {
            // 端の印が軌道の丸い端からはみ出さないよう、印の半径だけ内側に描く
            let inset = Layout.timelineMarkerDiameter / 2
            VStack(spacing: Spacing.micro) {
                LabelRow(font: .Small.regular) { width in
                    let nowX = min(
                        max(inset + timeline.fraction(of: timeline.now) * (width - inset * 2), nowLabelWidth / 2),
                        width - nowLabelWidth / 2
                    )
                    Text("Now \(timeline.now.formatted(date: .omitted, time: .shortened))", comment: "Label above the current time on the run timeline of a launchd job, e.g. Now 9:34 PM")
                        .font(.Small.regular)
                        .monospacedDigit()
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { nowLabelWidth = $0 }
                        .position(x: nowX, y: 0)

                    // 起動の見出しは印の真上に置き、「今」の見出しに重なるなら左へ逃がす。範囲より前に起動していれば左端に置く
                    if
                        let since = timeline.runningSince,
                        let startLabel = timeline.startLabel
                    {
                        let markX = inset + max(timeline.fraction(of: since), 0) * (width - inset * 2)
                        let limit = nowX - nowLabelWidth / 2 - Spacing.tight - startLabelWidth / 2
                        // 色は帯に持たせ、文字は「今」の見出しと同じ本文の色で読みやすくする
                        Text(verbatim: startLabel)
                            .font(.Small.regular)
                            .monospacedDigit()
                            .fixedSize()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { startLabelWidth = $0 }
                            .position(x: max(min(markX, limit), startLabelWidth / 2), y: 0)
                    }
                }

                GeometryReader { proxy in
                    let midY = proxy.size.height / 2
                    let x = { (date: Date) in inset + timeline.fraction(of: date) * (proxy.size.width - inset * 2) }

                    ZStack(alignment: .topLeading) {
                        Capsule()
                            .fill(.quaternary)
                            .frame(width: proxy.size.width, height: Layout.timelineTrackHeight)
                            .position(x: proxy.size.width / 2, y: midY)

                        // 起動した時刻が見えている範囲より前（または分からない）なら、左端から塗る
                        if timeline.isAlwaysRunning {
                            let minX = timeline.runningSince.map { max(x($0), 0) } ?? 0
                            let maxX = x(timeline.now)
                            Capsule()
                                .fill(ItemStatus.running.color)
                                .frame(width: max(maxX - minX, Layout.timelineTrackHeight), height: Layout.timelineTrackHeight)
                                .position(x: (minX + maxX) / 2, y: midY)
                        }

                        // 目盛りは軌道の下の短い刻みにする。毎時・毎月の予定は目盛りと同じ位置に来るので、軌道を貫く線だと白抜きの点を割ってしまう
                        ForEach(timeline.ticks, id: \.self) { tick in
                            Rectangle()
                                .fill(.tertiary)
                                .frame(width: Layout.timelineHairlineWidth, height: Spacing.micro)
                                .position(x: x(tick), y: midY + (Layout.timelineMarkerDiameter + Spacing.micro) / 2)
                        }

                        // ツールチップが印の上だけで出るよう、`.position` で広がる前に付ける
                        // 8pt の点ではポインタを合わせにくいので、ツールチップの出る範囲だけ広げる
                        ForEach(timeline.runs, id: \.self) { run in
                            RunDot(isPast: timeline.ranUntil.map { run <= $0 } ?? false)
                                .padding(Spacing.micro)
                                .contentShape(.rect)
                                .help(MonitoredItem.format(run))
                                .position(x: x(run), y: midY)
                        }

                        Rectangle()
                            .fill(.primary)
                            .frame(width: Layout.timelineHairlineWidth, height: proxy.size.height)
                            .position(x: x(timeline.now), y: midY)

                        // これからの予定の白抜きと色だけで分かれないよう、斜線で「走らなかった」を形でも示す
                        if let missedRun = timeline.missedRun {
                            Image(systemName: "circle.slash")
                                .font(.Body.regular)
                                .fontWeight(.semibold)
                                .foregroundStyle(status.color)
                                .help(status.fullReason ?? status.title)
                                .position(x: x(missedRun), y: midY)
                        }

                        if
                            let since = timeline.runningSince,
                            timeline.interval.contains(since)
                        {
                            // ▶ はすぐ上のツールバーの「今すぐ実行」と同じ形になるので、帯と同じ色の丸で始まりを示す
                            Circle()
                                .fill(ItemStatus.running.color)
                                .frame(width: Layout.timelineMarkerDiameter, height: Layout.timelineMarkerDiameter)
                                .help(MonitoredItem.format(since))
                                .position(x: x(since), y: midY)
                        }

                        if let lastRun = timeline.lastRun {
                            Image(systemName: timeline.lastRunStatus?.systemImage ?? "circle.fill")
                                .font(.Body.regular)
                                /**
                                 ✓・✗ は記号の中で抜けていて、下の「今」の線や軌道が透けるので、抜けた部分を白で塗る。
                                 成否を言えないときの無地の丸は1層なので、1つ目の色で全体が塗られる。白くならないよう同じ色を渡す
                                 */
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(
                                    timeline.lastRunStatus == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white),
                                    timeline.lastRunStatus.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary)
                                )
                                .help(MonitoredItem.lastRunText(lastRun, style: .absolute, now: timeline.now))
                                .position(x: x(lastRun), y: midY)
                        }

                        if let nextRun = timeline.nextRun {
                            // 呼吸で膨らむ分、ほかの印より大きく見えないよう一段小さくする
                            Image(systemName: "circle.fill")
                                .font(.Body.regular)
                                .imageScale(.small)
                                .foregroundStyle(.tint)
                                // 薄くなると止めた予定に見えるので、色は保ったまま大きさだけで呼吸させる
                                .symbolEffect(.breathe.plain, options: .repeat(.continuous), isActive: !reduceMotion)
                                .help(MonitoredItem.nextRunText(nextRun, now: timeline.now))
                                .position(x: x(nextRun), y: midY)
                        }
                    }
                }
                .frame(height: Layout.timelineHeight)

                LabelRow(font: .Small.regular) { width in
                    ForEach(timeline.labeledTicks, id: \.self) { tick in
                        Text(timeline.tickLabel(tick))
                            .font(.Small.regular)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            // 幅0の枠に左寄せ・中央寄せで置き、文字を目盛りから右へ、または目盛りを中心に出す
                            .frame(width: 0, alignment: timeline.scale.labelAlignment)
                            .offset(x: timeline.scale.labelAlignment == .leading ? Spacing.micro : 0)
                            .position(x: inset + timeline.fraction(of: tick) * (width - inset * 2), y: 0)
                    }
                }

                if let note = timeline.note {
                    // 帯には同じ色の見本を添え、緑の帯が何を表すかを読み取れるようにする
                    HStack(spacing: Spacing.tight) {
                        if timeline.isAlwaysRunning {
                            Capsule()
                                .fill(ItemStatus.running.color)
                                .frame(width: Layout.timelineSwatchWidth, height: Layout.timelineTrackHeight)
                        }

                        Text(note)
                            .font(.Base.regular)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Spacing.micro)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Timeline", comment: "Accessibility label of the run timeline of a launchd job: scheduled runs, the last run and now"))
            .accessibilityValue(Text(verbatim: timeline.accessibilityValue(status: status)))
        }
    }

    /// 1行の見出しを横の位置で並べる行。高さは文字の大きさで決まるので、見えない1文字で高さを取り、行の中央を y = 0 にして渡す
    struct LabelRow<Content: View>: View {
        let font: Font
        @ViewBuilder let content: (CGFloat) -> Content

        var body: some View {
            Text(verbatim: " ")
                .font(font)
                .frame(maxWidth: .infinity)
                .overlay {
                    GeometryReader { proxy in
                        content(proxy.size.width)
                            .offset(y: proxy.size.height / 2)
                    }
                }
        }
    }

    /// 予定の印。色は次回に譲る。走った予定は塗り、これからの予定と走ったか分からない予定は白抜きにして、起きたことと予定を形で分ける
    struct RunDot: View {
        let isPast: Bool

        var body: some View {
            Group {
                if isPast {
                    Circle()
                        .fill(.secondary)
                } else {
                    Circle()
                        .strokeBorder(.secondary, lineWidth: Layout.timelineDotStrokeWidth)
                }
            }
            .frame(width: Layout.timelineRunDiameter, height: Layout.timelineRunDiameter)
        }
    }
}
