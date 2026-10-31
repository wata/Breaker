import SwiftUI
import UserNotifications

@main
struct BreakerApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 一覧は1枚あれば足り、通知のタップで「開いていれば前面へ、閉じていれば開く」を openWindow だけで済ませるため、WindowGroup ではなく Window にする
    var body: some Scene {
        Window("Breaker", id: Self.mainWindowID) {
            MainWindow(appDelegate: appDelegate)
        }
        .commands {
            MenuCommands(updater: appDelegate.updater)
        }

        Settings {
            // 見本データのときは、トグルでログイン項目を登録せず、監視するアプリの選択も実際の設定に書かない
            if AppEnvironment.usesSampleData() {
                SettingsView(viewModel: .init(loginItem: PreviewLoginItem(status: .enabled), defaults: .preview))
            } else {
                SettingsView(viewModel: .init(refreshItems: { [appModel = appDelegate.appModel] in
                    await appModel.refresh()
                }))
            }
        }
    }
}

/// AppDelegate からは SwiftUI の openWindow を呼べないので、ウインドウが出たときに渡しておく
private struct MainWindow: View {
    let appDelegate: AppDelegate

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(appModel: appDelegate.appModel)
            .onAppear {
                appDelegate.openMainWindow = {
                    openWindow(id: BreakerApp.mainWindowID)
                }
            }
    }
}

/**
 定期チェックと通知はウインドウの有無に関係なく続けるので、ウインドウではなくアプリの起動に合わせて始める。
 そのため、ウインドウと定期チェックで共有する `AppModel` もここで持つ。Sparkle の自動アップデートも同じくアプリの起動に合わせて始める
 */
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let appModel = AppEnvironment.usesSampleData() ? AppModel.sampleData() : AppModel()
    let updater = AppUpdater()
    var openMainWindow: (() -> Void)?

    /// テストホストやプレビュー、見本データで起動されたときは、実際の検出・通知の許可・Dock バッジに触れない
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard
            !AppEnvironment.isIsolated(),
            !AppEnvironment.usesSampleData()
        else {
            return
        }
        let reporter = AbnormalReporter()
        UNUserNotificationCenter.current().delegate = self
        appModel.startMonitoring(reporter: reporter)
        Task {
            await reporter.requestAuthorization()
        }
    }

    /// ウインドウを閉じても常駐して定期チェックと通知を続け、Dock から再度開けるようにする
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            openMainWindow?()
        }
        return true
    }

    /// 前面にいるときも、別の項目の異常に気づけるようバナーを出す
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let itemID = response.notification.request.content.userInfo[AbnormalReporter.itemIDKey] as? MonitoredItem.ID
        await reveal(itemID: itemID)
    }

    private func reveal(itemID: MonitoredItem.ID?) {
        appModel.reveal(itemID: itemID)
        NSApp.activate()
        openMainWindow?()
    }
}
