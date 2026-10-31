import SwiftUI

extension BreakerApp {
    /**
     メニューバーの「項目」と「表示」。一覧のウインドウが手前にあるときだけ効くよう、`AppModel` は AppDelegate から直に取らず
     ウインドウが `focusedSceneValue` で渡したものを使う（設定のウインドウが手前なら無効になる）。
     アップデートの確認はどのウインドウが手前でも使えるよう、AppDelegate の `AppUpdater` を直に受け取る
     */
    struct MenuCommands: Commands {
        let updater: AppUpdater

        @FocusedValue(AppModel.self) private var appModel

        var body: some Commands {
            // Mac のアプリではアプリ名のメニューの「〜について」の下がアップデートの確認の定位置
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            CommandMenu("Item") {
                ItemMenu(appModel: appModel)
            }

            CommandGroup(after: .toolbar) {
                ViewMenu(appModel: appModel)
            }
        }
    }
}

extension BreakerApp {
    /**
     選んでいる項目へのツールバーと同じ操作。メニューバーの項目は選んでいるものによって組を変えず、
     launchd ジョブ以外を選んでいる・何も選んでいないときも同じ3つを無効で見せる。
     ショートカットは付けない（ツールバーや右クリックにも無く、ジョブを走らせる・止める操作を打ち間違いで起こさないため）
     */
    struct ItemMenu: View {
        let appModel: AppModel?

        var body: some View {
            let item = appModel?.selectedItem
            ItemActionMenuItems(actions: item?.launchdJobActions ?? ItemAction.unavailableJobActions) { action in
                guard
                    let appModel,
                    let item
                else {
                    return
                }
                Task {
                    await appModel.request(action, on: item)
                }
            }
            .disabled(appModel?.actingItemID != nil)
        }
    }

    /// サイドバーの絞り込みと下端の帯の更新を、メニューバーとキーボードからも使えるようにする
    struct ViewMenu: View {
        let appModel: AppModel?

        var body: some View {
            if let appModel {
                FilterMenuItems(appModel: appModel)
            } else {
                SidebarView.FilterMenuItems(launchdScope: .constant(.home), showsAbnormalOnly: .constant(false))
                    .disabled(true)
            }

            Divider()

            Button("Refresh") {
                Task {
                    await appModel?.refresh()
                }
            }
            .keyboardShortcut("r")
            .disabled(appModel?.isRefreshing ?? true)

            Divider()
        }
    }

    /// `@FocusedValue` の `AppModel` から Binding を作るため、`@Bindable` で受け取る View を挟む
    struct FilterMenuItems: View {
        @Bindable var appModel: AppModel

        var body: some View {
            SidebarView.FilterMenuItems(launchdScope: $appModel.launchdScope, showsAbnormalOnly: $appModel.showsAbnormalOnly)
        }
    }
}
