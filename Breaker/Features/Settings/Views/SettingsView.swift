import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// ⌘, で開く設定ウインドウ
struct SettingsView: View {
    @State private var viewModel: ViewModel

    init(viewModel: ViewModel = ViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Form {
            Section {
                // システム設定 > 一般 > ログイン項目の表記に合わせる
                Toggle(
                    "Open at Login",
                    isOn: Binding(get: { viewModel.launchesAtLogin }, set: { viewModel.setLaunchesAtLogin($0) })
                )

                // 一度だけの設定の案内なので、異常のように目立たせず小さく添える。文だけで何をすればよいか読めるよう、許可する場所（ログイン項目）も文で言う
                if viewModel.loginItemStatus == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items") {
                            viewModel.openSystemSettings()
                        }
                    } label: {
                        Label {
                            Text("Approve Breaker in Login Items to open it at login.")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.caution)
                        }
                        .font(.Base.regular)
                    }
                }

                if let failureMessage = viewModel.failureMessage {
                    Label(failureMessage, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(Color.Status.failure)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Breaker keeps running after you close its window, so it can notify you when something breaks.")
                    .font(.Small.regular)
                    .foregroundStyle(.secondary)
            }

            /**
             Form の中に List を入れると、プレビューでは SwiftUI の内部（TableViewListCore_Mac2）で落ちて描けないため、
             行を Form にそのまま並べ、各行に削除ボタンを置く。削除はたまにしか使わないので、ボタンはカーソルを合わせた行にだけ出す
             */
            Section {
                if viewModel.monitoredApps.isEmpty {
                    Text("No Apps")
                        .foregroundStyle(.secondary)
                }

                ForEach(viewModel.monitoredApps) { app in
                    MonitoredAppRow(app: app) {
                        Task {
                            await viewModel.removeMonitoredApp(app)
                        }
                    }
                }

                Button("Add App…", systemImage: "plus") {
                    Task {
                        await viewModel.addMonitoredApps(at: Self.chooseApps())
                    }
                }
                .buttonStyle(.borderless)
                // 枠の無いボタンは Form の中で二次的な文字の灰色になり、「No Apps」と並ぶと押せないように見えるので、アクセントの色にする
                .foregroundStyle(.tint)
                .help("Choose apps in /Applications to add")
            } header: {
                Text("Monitored Apps")
            } footer: {
                Text("Breaker shows in the sidebar whether these apps are running. You won't be notified when one quits.")
                    .font(.Small.regular)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: Layout.settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                viewModel.reloadStatus()
            }
        }
    }
}

extension SettingsView {
    /// 複数選べる。Mac で動く iPhone / iPad アプリも選べてしまうが、Bundle ID が読めないので追加の段階で飛ばす
    private static func chooseApps() async -> [URL] {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Add", comment: "Button in the open panel that adds the chosen apps")
        return await panel.begin() == .OK ? panel.urls : []
    }

    /**
     削除のボタンはカーソルを合わせたときと、キーボードで行を選んだとき（Tab で移って Delete で消せる）にだけ出す。
     VoiceOver ではボタンが見えなくても、行の操作と右クリックメニューから消せる。
     アプリが見つからない行は、選んだことは残したまま、汎用のアイコンを薄くして見つからないことを言う
     */
    struct MonitoredAppRow: View {
        let app: MonitoredApp
        let remove: () -> Void

        @State private var isHovering = false
        @FocusState private var isFocused: Bool

        var body: some View {
            HStack(spacing: Spacing.tight) {
                if let appURL = app.appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path(percentEncoded: false)))
                        .resizable()
                        .frame(width: Layout.appIconSize, height: Layout.appIconSize)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(for: .applicationBundle))
                        .resizable()
                        .frame(width: Layout.appIconSize, height: Layout.appIconSize)
                        .opacity(Opacity.dimmed)
                }

                VStack(alignment: .leading) {
                    Text(app.name)
                        .foregroundStyle(app.appURL == nil ? .secondary : .primary)

                    if app.appURL == nil {
                        Text("Not Found")
                            .font(.Small.regular)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(app.bundleID)

                Spacer()

                if isHovering || isFocused {
                    Button("Remove", systemImage: "minus.circle", action: remove)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove from the list")
                }
            }
            .contentShape(.rect)
            .onHover { isHovering = $0 }
            .focusable()
            .focused($isFocused)
            .onDeleteCommand(perform: remove)
            .contextMenu {
                Button("Remove", action: remove)
            }
            .accessibilityAction(named: Text("Remove"), remove)
        }
    }
}

#Preview("Monitored Apps") {
    let defaults = UserDefaults.preview
    defaults.set(["com.apple.Safari", "com.apple.TextEdit", "com.example.missing"], forKey: MonitoredAppSource.bundleIDsKey)
    return SettingsView(viewModel: .init(loginItem: PreviewLoginItem(status: .enabled), defaults: defaults))
}

#Preview("Requires Approval") {
    SettingsView(viewModel: .init(loginItem: PreviewLoginItem(status: .requiresApproval), defaults: .preview))
}

#Preview("Not Registered") {
    SettingsView(viewModel: .init(loginItem: PreviewLoginItem(status: .disabled), defaults: .preview))
}
