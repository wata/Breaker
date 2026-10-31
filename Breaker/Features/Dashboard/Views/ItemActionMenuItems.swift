import SwiftUI

/// 詳細ペインのツールバーの「その他」メニューとサイドバーの右クリックメニューで共有する
struct ItemActionMenuItems: View {
    let actions: [ItemAction]
    let perform: (ItemAction) -> Void

    var body: some View {
        ForEach(actions) { action in
            Button(action.title, systemImage: action.systemImage) {
                perform(action)
            }
            .disabled(!action.isEnabled)
        }
    }
}
