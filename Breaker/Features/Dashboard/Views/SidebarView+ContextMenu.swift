import SwiftUI

extension SidebarView {
    /**
     詳細ペインのツールバーとスケジュールの「編集…」と同じ項目を、状態を変える操作 → 編集 → ファイルの順に、空でない組の間を区切って並べる。
     今できない操作（cron の今すぐ実行、読み込み済みのジョブの読み込み直しなど）は、ツールバーでは無効で見せるが、
     コンテキストメニューには並べない（HIG: コンテキストメニューは使えない項目を薄くせず隠す）
     */
    struct ContextMenu: View {
        let item: MonitoredItem
        let isLocked: Bool
        let perform: (ItemAction) -> Void

        var body: some View {
            let controls = (item.controlActions + item.secondaryControlActions).filter(\.isEnabled)
            let groups = [controls, item.editActions, item.fileActions()].filter { !$0.isEmpty }
            Group {
                ForEach(groups, id: \.self) { actions in
                    if actions != groups.first {
                        Divider()
                    }

                    ItemActionMenuItems(actions: actions, perform: perform)
                }
            }
            .disabled(isLocked)
        }
    }
}
