import SwiftUI

extension ItemDetailView {
    /// 経路図の1段。つながらない原因を根に近い順に追えるよう、判定（`NetworkCheck.finding`）と同じ順に並べる
    struct RouteStage: Identifiable, Equatable {
        enum Kind: CaseIterable {
            case mac
            case router
            case internet
            case dns
        }

        enum State: Equatable {
            case reached
            /// 項目の状態を決めた問題がこの段にある。揺れ止め中の接続の失敗は要確認になる
            case cause(ItemStatus)
            /// 手前で切れている・まだ測っていない
            case unreached
        }

        let kind: Kind
        let state: State
        /// 段の下に出す値（遅延・接続の種類など）
        let value: String

        var id: Kind {
            kind
        }

        /**
         原因の段より先は、接続の失敗なら届いていないものとして薄くする（ルーターで切れていても、DNS はキャッシュで引けてしまうことがある）。
         ルーターは ping に応答しなくても、先のインターネットに届いていれば通れているので、失敗にしない
         */
        static func stages(of health: NetworkHealth, cause: Cause, locale: Locale = .current) -> [RouteStage] {
            let internetReached = health.internetAccess == .reachable
                || health.internetAccess == .captivePortal
                || (health.internetPing?.receivedCount ?? 0) > 0
            let candidates: [(kind: Kind, highlight: ItemStatus?, isReached: Bool, value: String)] = [
                (
                    .mac,
                    cause.highlight(for: [.offline, .weakWiFiSignal]),
                    health.pathStatus != .unsatisfied,
                    health.pathStatus == .unsatisfied ? health.pathStatus.title : health.interface.title
                ),
                (
                    .router,
                    cause.routerStatus,
                    (health.routerPing?.receivedCount ?? 0) > 0 || internetReached,
                    routerValue(of: health.routerPing, isCause: cause.routerStatus != nil, locale: locale)
                ),
                (
                    .internet,
                    cause.highlight(for: [.internetUnreachable, .captivePortal, .packetLoss, .highLatency]),
                    internetReached,
                    internetValue(of: health, cause: cause, locale: locale)
                ),
                (
                    .dns,
                    cause.highlight(for: [.dnsNotResponding]),
                    health.dnsLookup.map { $0.failureReason == nil } ?? false,
                    health.dnsLookup?.title(locale: locale) ?? NetworkHealth.placeholder
                ),
            ]
            var isCut = false
            return candidates.map { candidate in
                let state: State = if isCut {
                    .unreached
                } else if let highlight = candidate.highlight {
                    .cause(highlight)
                } else if candidate.isReached {
                    .reached
                } else {
                    .unreached
                }
                if
                    candidate.highlight != nil,
                    cause.finding?.isConnectionFailure == true
                {
                    isCut = true
                }
                return RouteStage(kind: candidate.kind, state: state, value: candidate.value)
            }
        }

        /// ロスが原因なら、遅延ではなくロス率を出す（届いた分だけの平均の遅延は当てにならず、原因の値でもない）
        private static func internetValue(of health: NetworkHealth, cause: Cause, locale: Locale) -> String {
            if
                let ping = health.internetPing,
                cause.highlight(for: [.packetLoss]) != nil
            {
                NetworkHealth.packetLossText(ping.lossRate, locale: locale)
            } else {
                health.internetPing?.averageMilliseconds.map { NetworkHealth.latencyText(milliseconds: $0, locale: locale) }
                    ?? health.internetAccess?.title
                    ?? NetworkHealth.placeholder
            }
        }

        private static func routerValue(of ping: NetworkHealth.PingResult?, isCause: Bool, locale: Locale) -> String {
            guard let ping else {
                return NetworkHealth.placeholder
            }
            if ping.receivedCount > 0 {
                return ping.averageMilliseconds.map { NetworkHealth.latencyText(milliseconds: $0, locale: locale) } ?? NetworkHealth.placeholder
            } else {
                return ping.unansweredText(isCause: isCause, locale: locale)
            }
        }
    }

    /**
     Mac → ルーター → インターネット → DNS を横に並べ、つなぎ目を先の段の状態の色で描く。どこで切れたかを一目で分かるようにする。
     段は同じ幅に割り、各段が左右のつなぎ目の半分ずつを描くので、隣の段の線とつながって見える
     */
    struct RouteDiagram: View {
        let stages: [RouteStage]

        var body: some View {
            let nextStates = stages.dropFirst().map { Optional($0.state) } + [nil]
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(zip(stages, nextStates)), id: \.0.id) { stage, nextState in
                    StageView(stage: stage, hasIncomingLine: stage.id != stages.first?.id, nextState: nextState)
                }
            }
            .padding(.vertical, Spacing.tight)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Route", comment: "Accessibility label of the network route diagram: Mac, router, internet and DNS"))
        }
    }
}

extension ItemDetailView.RouteDiagram {
    struct StageView: View {
        let stage: ItemDetailView.RouteStage
        let hasIncomingLine: Bool
        let nextState: ItemDetailView.RouteStage.State?

        var body: some View {
            VStack(spacing: Spacing.micro) {
                HStack(spacing: Spacing.micro) {
                    RouteLine(state: hasIncomingLine ? stage.state : nil)

                    /**
                     記号ごとに高さが違い、そのままだと段ごとに線の高さと名前の位置がずれる。全部の記号を見えない土台に重ねて枠をそろえ、
                     実際の記号をその中央に置く
                     */
                    ZStack {
                        ForEach(ItemDetailView.RouteStage.Kind.allCases, id: \.self) { kind in
                            Image(systemName: kind.systemImage)
                                .hidden()
                        }

                        Image(systemName: stage.kind.systemImage)
                            .foregroundStyle(stage.state.symbolColor)
                    }
                    .font(.Display.symbol)

                    RouteLine(state: nextState)
                }

                Text(stage.kind.title)

                HStack(alignment: .firstTextBaseline, spacing: Spacing.micro) {
                    if case .cause(let status) = stage.state {
                        ItemDetailView.StatusMark(status: status)
                    }

                    Text(stage.value)
                        .foregroundStyle(stage.state.valueColor)
                        .monospacedDigit()
                }
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stage.kind.title)
            .accessibilityValue(Text(verbatim: [stage.state.title, stage.value].formatted(.list(type: .and, width: .narrow))))
        }
    }

    /// つなぎ目の半分。届いていないところは色だけに頼らず破線にする。最初の段の左のように線が無いところも、記号を中央に置くため場所は取る
    struct RouteLine: View {
        let state: ItemDetailView.RouteStage.State?

        var body: some View {
            HorizontalLine()
                .stroke(
                    state?.lineColor ?? .clear,
                    style: StrokeStyle(lineWidth: Layout.routeLineWidth, dash: state == .unreached ? Layout.routeLineDash : [])
                )
                .frame(maxWidth: .infinity)
                .frame(height: Layout.routeLineWidth)
                .accessibilityHidden(true)
        }
    }

    struct HorizontalLine: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

extension ItemDetailView.RouteStage.Kind {
    var title: String {
        switch self {
        // 製品名・略語なので訳さない
        case .mac:
            "Mac"

        case .router:
            String(localized: "Router", comment: "Row label in the network detail: IP address of the router (default gateway), and the router stage of the network route diagram")

        case .internet:
            String(localized: "Internet", comment: "Row label in the network detail: whether a page on the internet could be loaded, and the internet stage of the network route diagram")

        case .dns:
            "DNS"
        }
    }

    var systemImage: String {
        switch self {
        case .mac:
            "laptopcomputer"

        case .router:
            "wifi.router"

        case .internet:
            "globe"

        case .dns:
            "server.rack"
        }
    }
}

extension ItemDetailView.RouteStage.State {
    /// 読み上げで段の値の前に言う状態
    var title: String {
        switch self {
        case .reached:
            ItemStatus.ok.title

        case .cause(let status):
            status.title

        case .unreached:
            String(localized: "Not reached", comment: "Accessibility value of a stage in the network route diagram (router, internet, DNS) that couldn't be reached or wasn't checked")
        }
    }

    var lineColor: Color {
        switch self {
        case .reached:
            .Status.ok

        case .cause(let status):
            status.color

        case .unreached:
            .Status.inactive
        }
    }

    /// 正常な段の記号は本文の色で落ち着かせ、色は原因の段とつなぎ目に持たせる
    var symbolColor: Color {
        switch self {
        case .reached:
            .primary

        case .cause(let status):
            status.color

        case .unreached:
            .Status.inactive
        }
    }

    var valueColor: Color {
        if case .cause(let status) = self {
            status.color
        } else {
            .secondary
        }
    }
}
