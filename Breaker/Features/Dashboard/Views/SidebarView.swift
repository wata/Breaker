import SwiftUI

struct SidebarView: View {
    @Bindable var appModel: AppModel

    var body: some View {
        List(selection: $appModel.selectedID) {
            ForEach(appModel.sections) { section in
                Section {
                    ForEach(section.items) { item in
                        Row(item: item, showsKind: section.group == .attention)
                    }
                } header: {
                    SectionHeader(group: section.group, count: section.items.count)
                }
            }
        }
        .listStyle(.sidebar)
        // 選択中の項目ではなく右クリックした行が対象になるよう、行の ID で受け取る
        .contextMenu(forSelectionType: MonitoredItem.ID.self) { ids in
            if
                ids.count == 1,
                let item = appModel.items.first(where: { ids.contains($0.id) })
            {
                ContextMenu(item: item, isLocked: appModel.actingItemID != nil) { action in
                    Task {
                        await appModel.request(action, on: item)
                    }
                }
            }
        }
        .overlay {
            if
                let reason = appModel.emptyReason,
                !appModel.isRefreshing
            {
                EmptyState(reason: reason)
            }
        }
        /**
         最終更新と更新のボタンを下端の帯に固定する。safeAreaBar なので一覧の下端の余白が帯の分だけ広がり、
         最後の行も帯の上までスクロールして読める
         */
        .safeAreaBar(edge: .bottom, spacing: 0) {
            Footer(
                lastRefreshDate: appModel.lastRefreshDate,
                isRefreshing: appModel.isRefreshing
            ) {
                Task {
                    await appModel.refresh()
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                // 詳細ではなくサイドバーの一覧を絞るため、サイドバーに置く
                Menu("Filter", systemImage: appModel.hasCustomFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") {
                    FilterMenuItems(launchdScope: $appModel.launchdScope, showsAbnormalOnly: $appModel.showsAbnormalOnly)
                }
                .help("Filter the items in the list")
            }
        }
    }
}

extension SidebarView {
    /// 絞り込みボタンのメニューとメニューバーの「表示」で同じ並びを使う
    struct FilterMenuItems: View {
        @Binding var launchdScope: AppModel.LaunchdScope
        @Binding var showsAbnormalOnly: Bool

        var body: some View {
            Picker("Show", selection: $launchdScope) {
                ForEach(AppModel.LaunchdScope.allCases) { scope in
                    Text(scope.title)
                        .tag(scope)
                }
            }
            .pickerStyle(.inline)

            Toggle("Only Issues", isOn: $showsAbnormalOnly)
        }
    }

    /// 要確認の節は、メールの未読数と同じく見出しの後ろに件数を添える。件数は節に並んでいる行の数
    struct SectionHeader: View {
        let group: AppModel.Section.Group
        let count: Int

        var body: some View {
            HStack(spacing: Spacing.micro) {
                Text(group.title)

                if group == .attention {
                    Text(count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 絞り込みのせいで空なら、どの絞り込みを外せば見えるかを添える
    struct EmptyState: View {
        let reason: AppModel.EmptyReason

        var body: some View {
            switch reason {
            case .noItems:
                ContentUnavailableView("Nothing to Monitor", systemImage: "tray")

            case .noAbnormal(let hidesAbnormal):
                ContentUnavailableView {
                    Label("No Issues", systemImage: "checkmark.circle")
                } description: {
                    if hidesAbnormal {
                        Text("Show All to see issues with other launchd jobs.")
                    }
                }

            case .noJobs(let scope):
                ContentUnavailableView {
                    Label(scope.emptyTitle, systemImage: "tray")
                } description: {
                    Text(scope.emptyDescription)
                }
            }
        }
    }
}

extension AppModel.Section.Group {
    var title: String {
        switch self {
        case .attention:
            // 状態名の「要確認」と同じ言葉。失敗もここに入るが、どちらも見に行くべきものとして1つの言葉で呼ぶ
            String(localized: "Needs Attention", comment: "Status of an item that is running but should be checked, and the title of the sidebar section that gathers failed items and items that need attention")

        case .kind(let kind):
            kind.title
        }
    }
}

extension AppModel.LaunchdScope {
    var title: String {
        switch self {
        case .home:
            String(localized: "Home", comment: "Filter option: launchd jobs that run your scripts in your home folder")

        case .userAgents:
            String(localized: "User Agents", comment: "Filter option: launchd jobs in ~/Library/LaunchAgents")

        case .systemAgents:
            String(localized: "System Agents", comment: "Filter option: launchd jobs in /Library/LaunchAgents")

        case .daemons:
            String(localized: "Daemons", comment: "Filter option: launchd jobs in /Library/LaunchDaemons")

        case .all:
            String(localized: "All", comment: "Filter option: all launchd jobs")
        }
    }

    /// 一覧が空のときの見出し。`all` で空になるのは項目が1つも無いときなので、実際には出ない
    var emptyTitle: String {
        switch self {
        case .home:
            String(localized: "No Home Jobs")

        case .userAgents:
            String(localized: "No User Agents")

        case .systemAgents:
            String(localized: "No System Agents")

        case .daemons:
            String(localized: "No Daemons")

        case .all:
            String(localized: "No launchd Jobs")
        }
    }

    /// ホームで空なら、アプリが入れたジョブも出る範囲を勧める。それ以外は「すべて」に広げれば見える
    var emptyDescription: String {
        if self == .home {
            String(localized: "Show User Agents or All to see jobs installed by apps.")
        } else {
            String(localized: "Show All to see other launchd jobs.")
        }
    }
}

// ツールバーの絞り込みボタンを見るため、ウインドウと同じく NavigationSplitView に入れる
#Preview {
    NavigationSplitView {
        SidebarView(appModel: .preview(selectedID: MonitoredItem.samples[2].id))
            .navigationSplitViewColumnWidth(min: Layout.sidebarMinWidth, ideal: Layout.sidebarIdealWidth)
    } detail: {
        EmptyView()
    }
    .frame(width: Layout.sidebarIdealWidth * 2, height: Layout.minWindowHeight)
}
