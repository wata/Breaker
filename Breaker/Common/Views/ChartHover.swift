import Charts
import SwiftUI

extension View {
    /**
     グラフの上でポインタを動かしている間、その位置の日付を `date` に入れ、外れたら nil にする。
     値は線や面の形からは読み取れないので、ホバーで読めるようにする。グラフごとに近い記録を選び、`ChartTooltip` で見せる
     */
    func chartHoverDate(_ date: Binding<Date?>) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear
                    .contentShape(.rect)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            // 位置はグラフ全体（軸の文字も含む）が基準なので、描画域の左端からの位置に直す
                            let originX = proxy.plotFrame.map { geometry[$0].origin.x } ?? 0
                            date.wrappedValue = proxy.value(atX: location.x - originX, as: Date.self)

                        case .ended:
                            date.wrappedValue = nil
                        }
                    }
            }
        }
    }
}

extension Sequence {
    /// ホバーした日付にいちばん近い記録。記録は飛び飛びなので、ちょうどその日時の記録はまず無い
    func nearest(to date: Date, by keyPath: KeyPath<Element, Date>) -> Element? {
        min { abs($0[keyPath: keyPath].timeIntervalSince(date)) < abs($1[keyPath: keyPath].timeIntervalSince(date)) }
    }
}

extension View {
    /**
     ホバーの札を、幅 `width` の中の `x` の真上に置く（札の下端を、置いた枠の上端に合わせる）。
     中央に置くと両端で札がはみ出すので、左半分では札の左端を、右半分では右端を `x` に合わせる
     */
    func tooltipPlacement(x: CGFloat, width: CGFloat) -> some View {
        let isLeading = x < width / 2
        return frame(maxWidth: .infinity, alignment: isLeading ? .leading : .trailing)
            .padding(isLeading ? .leading : .trailing, isLeading ? x : width - x)
            .frame(width: width, height: 0, alignment: .bottom)
    }
}

/**
 グラフ・帯・タイムラインをホバーしたときの札。見出し（日時や印の説明）と値の行を並べる。
 値の行には系列の色の点を添え、どの線・どの色の値かを凡例と同じ色で結ぶ
 */
struct ChartTooltip: View {
    struct Row: Identifiable {
        let title: String
        let value: String
        let color: Color

        var id: String {
            title
        }
    }

    let title: String?
    var rows: [Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            if let title {
                Text(title)
                    .foregroundStyle(rows.isEmpty ? .primary : .secondary)
            }

            ForEach(rows) { row in
                HStack(spacing: Spacing.micro) {
                    Circle()
                        .fill(row.color)
                        .frame(width: Layout.legendDotSize, height: Layout.legendDotSize)

                    Text(row.title)

                    Spacer(minLength: Spacing.tight)

                    Text(row.value)
                        .monospacedDigit()
                }
            }
        }
        .font(.Base.regular)
        .fixedSize()
        .padding(Spacing.tight)
        .background(.regularMaterial, in: .rect(cornerRadius: Layout.chartTooltipCornerRadius))
    }
}
