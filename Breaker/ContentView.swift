import SwiftUI

struct ContentView: View {
    @Bindable var appModel: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(appModel: appModel)
                .navigationSplitViewColumnWidth(min: Layout.sidebarMinWidth, ideal: Layout.sidebarIdealWidth)
        } detail: {
            if let item = appModel.selectedItem {
                ItemDetailView(
                    item: item,
                    refreshDate: appModel.lastRefreshDate,
                    actingItemID: appModel.actingItemID,
                    note: appModel.itemNotes[item.id],
                    saveNote: { appModel.saveNote($0, for: item) }
                ) { action in
                    Task {
                        await appModel.request(action, on: item)
                    }
                }
                    .navigationSplitViewColumnWidth(min: Layout.detailMinWidth, ideal: Layout.detailMinWidth)
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.left")
            }
        }
        // メールやメモと同じく、選んでいるものをタイトルにする。HIG がウインドウのタイトルにアプリ名を使わないよう求めているので、未選択なら空にする
        .navigationTitle(appModel.selectedItem?.name ?? "")
        .confirmationDialog("Stop this job?", isPresented: $appModel.isConfirming, presenting: appModel.pendingAction) { pending in
            Button(ItemAction.stopTitle, role: .destructive) {
                Task {
                    await appModel.perform(pending.action, on: pending.item)
                }
            }
        } message: { pending in
            Text("\(pending.item.name) will be stopped with launchctl disable and bootout. It stays stopped after you log in again.")
        }
        .sheet(item: $appModel.scheduleEditing) { editing in
            ScheduleEditorView(
                job: editing.job,
                hasComments: editing.hasComments,
                isSaving: appModel.actingItemID == editing.id,
                failureMessage: appModel.scheduleSaveFailure
            ) { schedule in
                Task {
                    await appModel.saveSchedule(schedule, for: editing)
                }
            }
            // 保存中に Esc などで閉じると、書き込みの結果を見届けられないので閉じさせない
            .interactiveDismissDisabled(appModel.actingItemID == editing.id)
        }
        .alert("The action failed.", isPresented: $appModel.isShowingFailure, presenting: appModel.failureMessage) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .frame(minWidth: Layout.minWindowWidth, minHeight: Layout.minWindowHeight)
        // メニューバーの「項目」「表示」が、このウインドウが手前にあるときだけ選択と絞り込みを扱えるようにする
        .focusedSceneValue(appModel)
    }
}

#Preview {
    ContentView(appModel: .preview(selectedID: MonitoredItem.samples[2].id))
}
