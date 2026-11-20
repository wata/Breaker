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
        @FocusedValue(SpeedTestScheduler.self) private var speedTestScheduler
        @FocusedValue(StorageScanScheduler.self) private var storageScanScheduler

        var body: some Commands {
            // Mac のアプリではアプリ名のメニューの「〜について」の下がアップデートの確認の定位置
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            CommandMenu("Item") {
                ItemMenu(appModel: appModel, speedTestScheduler: speedTestScheduler, storageScanScheduler: storageScanScheduler)
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
     対象外の項目を選んでいる・何も選んでいないときも同じ組を無効で見せる。
     ショートカットは付けない（ツールバーや右クリックにも無く、ジョブを走らせる・止める操作を打ち間違いで起こさないため）
     */
    struct ItemMenu: View {
        let appModel: AppModel?
        let speedTestScheduler: SpeedTestScheduler?
        let storageScanScheduler: StorageScanScheduler?

        var body: some View {
            let item = appModel?.selectedItem
            Group {
                ItemActionMenuItems(actions: item?.launchdJobActions ?? ItemAction.unavailableJobActions) { action in
                    request(action, on: item)
                }

                Divider()

                ItemActionMenuItems(actions: [item?.editActions.first ?? ItemAction.unavailableEditAction]) { action in
                    request(action, on: item)
                }

                Divider()

                ItemActionMenuItems(actions: [item?.promptAction ?? ItemAction.unavailablePromptAction]) { action in
                    request(action, on: item)
                }

                Divider()

                // ツールバーを隠しても計測できるよう、詳細のツールバーと同じ条件で置く
                Button("Measure Now") {
                    Task {
                        await speedTestScheduler?.measureNow()
                    }
                }
                .disabled(
                    speedTestScheduler?.isMeasuring ?? true
                        || !(item?.networkHealth?.isOnline ?? false)
                )

                // 計測と同じく、ツールバーを隠しても調べられるよう詳細のツールバーと同じ条件で置く
                Button("Scan Now") {
                    Task {
                        await storageScanScheduler?.scanNow()
                    }
                }
                .disabled(storageScanScheduler?.isScanning ?? true || item?.storageUsage == nil)
            }
            .disabled(appModel?.actingItemID != nil)
        }

        private func request(_ action: ItemAction, on item: MonitoredItem?) {
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
