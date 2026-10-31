import SwiftUI

extension ItemDetailView {
    /// 有効かどうかはヘッダーの状態に出ているので、ここではフォルダとスクリプトだけを出す
    struct FolderActionSection: View {
        let action: MonitoredItem.FolderAction
        let isFolderMissing: Bool
        let isLocked: Bool
        let perform: (ItemAction) -> Void

        var body: some View {
            // 要確認の節で理由の前に添える種類と同じ言葉にする
            Section(MonitoredItem.Kind.folderAction.shortTitle) {
                PathRow(title: "Folder", url: action.folderURL, isLocked: isLocked, isMissing: isFolderMissing, perform: perform)

                // スクリプトもファイルなので、フォルダのパスと同じ等幅にそろえる
                LabeledContent("Scripts") {
                    Text(action.scriptNames.isEmpty ? "—" : action.scriptNames.joined(separator: "\n"))
                        .font(.Mono.regular)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
