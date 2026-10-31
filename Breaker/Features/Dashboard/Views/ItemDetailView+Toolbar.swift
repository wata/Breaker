import SwiftUI

extension ItemDetailView {
    /**
     よく使う状態を変える操作はアイコンのボタンで並べ、それ以外（読み込み直すとファイルを開く操作）は1つのメニューにまとめる。
     ボタンの組は状態で変えず、できないものは無効にする。ツールバーのボタンは文字を出さないので、何をするかはツールチップで伝える
     */
    struct Toolbar: ToolbarContent {
        let controls: [ItemAction]
        let secondaryControls: [ItemAction]
        let files: [ItemAction]
        let isLocked: Bool
        let perform: (ItemAction) -> Void

        var body: some ToolbarContent {
            ToolbarItemGroup {
                ForEach(controls) { action in
                    Button(action.title, systemImage: action.systemImage) {
                        perform(action)
                    }
                    .help(action.title)
                    .disabled(isLocked || !action.isEnabled)
                }

                if !secondaryControls.isEmpty || !files.isEmpty {
                    Menu("More", systemImage: "ellipsis.circle") {
                        ItemActionMenuItems(actions: secondaryControls, perform: perform)

                        if !secondaryControls.isEmpty && !files.isEmpty {
                            Divider()
                        }

                        ItemActionMenuItems(actions: files, perform: perform)
                    }
                    .help("More")
                    .disabled(isLocked)
                }
            }
        }
    }
}
