import SwiftUI

/**
 サイドバーの行の状態。赤・橙・緑は小さいと見分けにくく、色覚によっては同じに見えるので、色に加えて形（詳細ヘッダーと同じシンボル）で伝える。
 読み上げでは状態名を返す
 */
struct StatusSymbol: View {
    let item: MonitoredItem

    /// サイドバーの外では既定の .medium が入るので、中の大きさになる
    @Environment(\.sidebarRowSize) private var rowSize

    var body: some View {
        /**
         三角の記号だけ丸より幅が広く、そのままだと行の名前の書き出し位置がずれる。いちばん幅の広い三角を見えない土台にして枠の幅を決め、
         実際の記号をその中央に重ねる。土台も同じフォントで描くので、行の大きさ（小・中・大）に合わせて枠も伸び縮みする
         */
        Image(systemName: ItemStatus.widestSystemImage)
            .hidden()
            .overlay {
                Image(systemName: item.statusSystemImage)
                    .foregroundStyle(item.status.color)
            }
            .font(.SidebarStatus.regular(for: rowSize))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.status.title)
    }
}

#Preview {
    HStack(spacing: Spacing.tight) {
        ForEach(MonitoredItem.samples) { item in
            StatusSymbol(item: item)
        }
    }
    .padding(Spacing.comfortable)
}
