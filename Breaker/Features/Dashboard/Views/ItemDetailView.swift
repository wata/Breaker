import SwiftUI

struct ItemDetailView: View {
    let item: MonitoredItem
    /// ログ末尾を一覧の更新に合わせて読み直すためのきっかけ
    let refreshDate: Date?
    /// 操作中の項目。この項目ならくるくるを出し、どの項目でも操作中はボタンを押せなくする
    let actingItemID: MonitoredItem.ID?
    /// 利用者のメモ。無ければ自動で取った説明を薄く見せる
    let note: String?
    /// ネットワークの詳細の速度は、項目の更新を待たずに計測の状態を見せるため直接観測する
    let speedTestScheduler: SpeedTestScheduler
    let saveNote: (String) -> Void
    let perform: (ItemAction) -> Void

    var body: some View {
        let isLocked = actingItemID != nil
        Form {
            Header(
                item: item,
                isActing: actingItemID == item.id,
                isLocked: isLocked,
                note: note,
                refreshDate: refreshDate,
                saveNote: saveNote,
                perform: perform
            )
                // 入力途中の下書きを別の項目へ持ち越さない
                .id(item.id)

            switch item.detail {
            case .launchdJob(let job):
                LaunchdJobSections(
                    job: job,
                    isAbnormal: item.status.isAbnormal,
                    edits: item.editActions,
                    isLocked: isLocked,
                    refreshDate: refreshDate,
                    perform: perform
                )

            case .cronJob(let job):
                CronJobSections(
                    job: job,
                    isAbnormal: item.status.isAbnormal,
                    isLocked: isLocked,
                    refreshDate: refreshDate,
                    perform: perform
                )

            case .folderAction(let action):
                FolderActionSection(
                    action: action,
                    isFolderMissing: item.status == FolderActionSource.missingFolderStatus,
                    isLocked: isLocked,
                    perform: perform
                )

            case .network(let health):
                NetworkSections(health: health, status: item.status, speedTestScheduler: speedTestScheduler)

            case .sourceFailure:
                // 理由はヘッダーに出ている。検出し直すにはサイドバーの更新（⌘R）を使う
                EmptyView()
            }
        }
        .formStyle(.grouped)
        .toolbar {
            Toolbar(
                itemID: item.id,
                controls: item.controlActions,
                promptAction: item.promptAction,
                secondaryControls: item.secondaryControlActions,
                files: item.fileActions(),
                measure: item.networkHealth.map { .init(scheduler: speedTestScheduler, isOnline: $0.isOnline) },
                isLocked: isLocked,
                perform: perform
            )
        }
    }
}

extension String {
    /// 詳細ペインのパスはホーム配下が多いので `~` で縮めて読みやすくする
    var abbreviatingHome: String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}

#Preview("launchd (Failed)") {
    ItemDetailView(item: MonitoredItem.samples[2], refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth + Layout.sidebarIdealWidth, height: Layout.minWindowHeight * 2)
}

#Preview("launchd (Failed with Logs)") {
    ItemDetailView(item: MonitoredItem.sampleFailureWithLogs, refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth + Layout.sidebarIdealWidth, height: Layout.minWindowHeight * 2)
}

#Preview("launchd (With Note)") {
    ItemDetailView(item: MonitoredItem.samples[0], refreshDate: nil, actingItemID: nil, note: "Checks the certificate expiry on the 1st of every month", speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight * 2)
}

#Preview("launchd (Acting)") {
    ItemDetailView(item: MonitoredItem.samples[0], refreshDate: nil, actingItemID: MonitoredItem.samples[0].id, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight * 2)
}

#Preview("launchd (Running)") {
    ItemDetailView(item: MonitoredItem.samples[1], refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight * 2)
}

#Preview("launchd (.plist.disabled)") {
    ItemDetailView(item: MonitoredItem.samples[4], refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight * 2)
}

#Preview("launchd (Not Loaded)") {
    ItemDetailView(item: MonitoredItem.samples[3], refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight * 2)
}

#Preview("launchd (Missed Run)") {
    ItemDetailView(item: MonitoredItem.samples[5], refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight * 2)
}

#Preview("launchd (Missing Script)") {
    ItemDetailView(item: MonitoredItem.samples[6], refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight * 2)
}

#Preview("launchd (Error in Log)") {
    ItemDetailView(item: MonitoredItem.sampleLogErrorWithLogs, refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight * 2)
}

#Preview("launchd (View-Only Daemon)") {
    ItemDetailView(item: MonitoredItem.sampleSystemDaemon, refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight * 2)
}

#Preview("cron") {
    ItemDetailView(item: MonitoredItem.sampleCronWithLogs, refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight * 2)
}

#Preview("cron (Missing Log Folder)") {
    ItemDetailView(item: MonitoredItem.samples[10], refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight)
}

#Preview("Folder Action") {
    ItemDetailView(item: MonitoredItem.samples[12], refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight)
}

#Preview("Network") {
    ItemDetailView(item: MonitoredItem.sampleNetwork, refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight * 2)
}

#Preview("Network (Needs Attention)") {
    ItemDetailView(item: MonitoredItem.sampleNetworkWarning, refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight * 2)
}

#Preview("Network (Offline)") {
    ItemDetailView(item: MonitoredItem.sampleNetworkOffline, refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight * 2)
}

#Preview("Discovery Failure") {
    ItemDetailView(item: MonitoredItem.sampleSourceFailure, refreshDate: nil, actingItemID: nil, note: nil, speedTestScheduler: .sampleData(), saveNote: { _ in }) { _ in }
        .frame(width: Layout.detailMinWidth, height: Layout.minWindowHeight)
}
