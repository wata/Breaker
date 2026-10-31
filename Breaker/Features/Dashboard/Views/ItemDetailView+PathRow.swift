import SwiftUI

extension ItemDetailView {
    /**
     パスの行はどれも1行にそろえる。長いパスは実行コマンドと同じく中央を省き、ホーム起点とファイル名の両方を残す。全文はツールチップで見せる
     */
    struct PathRow: View {
        let title: LocalizedStringKey
        let url: URL
        let isLocked: Bool
        /// 指している先が無いことが状態の理由になっているとき。どの行が問題かを警告の色と記号で示す
        var isMissing = false
        let perform: (ItemAction) -> Void

        var body: some View {
            let path = url.path(percentEncoded: false).abbreviatingHome
            /**
             LabeledContent は値が収まらないと値をラベルの下へ回し、行ごとに配置が変わってしまう。
             パスは省略してでも右に置き続けたいので、ラベルを縮めずに並べる
             */
            HStack(spacing: Spacing.tight) {
                Text(title)
                    .fixedSize()

                Spacer(minLength: Spacing.standard)

                if isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.Status.warning)
                        .accessibilityLabel("Not Found")
                }

                Text(path)
                    .font(.Mono.regular)
                    .foregroundStyle(isMissing ? Color.Status.warning : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(path)

                // 無いものは Finder で表示しても何も起きないので押せなくする
                RevealButton(url: url, isLocked: isLocked || isMissing, perform: perform)
            }
        }
    }

    /// 等幅のコマンドを折り返すとハイフンの位置で切れて読みにくいので、1行で中央を省き、全文はツールチップで見せる
    struct CommandRow: View {
        let title: LocalizedStringKey
        let command: String

        var body: some View {
            HStack(spacing: Spacing.tight) {
                Text(title)
                    .fixedSize()

                Spacer(minLength: Spacing.standard)

                Text(command)
                    .font(.Mono.regular)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(command)
            }
        }
    }

    /// パスの行とログの節の見出しに置く。右クリックメニューの「Finder で表示」と同じ操作
    struct RevealButton: View {
        let url: URL
        let isLocked: Bool
        /// ログの節は見出しにパスを出さないので、ここでパスを見せる。nil なら操作の名前
        var help: String?
        let perform: (ItemAction) -> Void

        var body: some View {
            Button(ItemAction.showInFinderTitle, systemImage: "magnifyingglass") {
                perform(ItemAction(title: ItemAction.showInFinderTitle, systemImage: "magnifyingglass", operation: .reveal(url)))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(help ?? ItemAction.showInFinderTitle)
            .disabled(isLocked)
        }
    }
}
