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
            // 見本データのときは、トグルでログイン項目を登録せず、位置情報の許可も求めず、設定も実際の値に書かない
            if AppEnvironment.usesSampleData() {
                SettingsView(viewModel: .init(loginItem: PreviewLoginItem(status: .enabled), locationAuthorization: PreviewLocationAuthorization(status: .authorized), defaults: .preview))
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
        ContentView(appModel: appDelegate.appModel, speedTestScheduler: appDelegate.speedTestScheduler, storageScanScheduler: appDelegate.storageScanScheduler)
            .onAppear {
                appDelegate.openMainWindow = {
                    openWindow(id: BreakerApp.mainWindowID)
                }
            }
    }
}

/**
 定期チェックと通知はウインドウの有無に関係なく続けるので、ウインドウではなくアプリの起動に合わせて始める。
 そのため、ウインドウと定期チェックで共有する `AppModel` もここで持つ。Sparkle の自動アップデートも同じくアプリの起動に合わせて始める。
 速度計測もウインドウを閉じても続け、メインウインドウと設定のどちらからも同じ状態を見せるので、`updater` と同じくここで持つ
 */
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let appModel: AppModel
    let speedTestScheduler: SpeedTestScheduler
    let storageScanScheduler: StorageScanScheduler
    let updater = AppUpdater()
    var openMainWindow: (() -> Void)?

    override init() {
        let models = AppEnvironment.usesSampleData()
            ? Models(appModel: .sampleData(), speedTestScheduler: .sampleData(), storageScanScheduler: .sampleData())
            : Self.makeLiveModels()
        appModel = models.appModel
        speedTestScheduler = models.speedTestScheduler
        storageScanScheduler = models.storageScanScheduler
        super.init()
    }

    /// テストホストやプレビュー、見本データで起動されたときは、実際の検出・速度計測・通知の許可・Dock バッジに触れない
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
        speedTestScheduler.start()
        storageScanScheduler.start()
        Task {
            await reporter.requestAuthorization()
        }
    }

    /// 計測中の networkQuality と走査中の du はアプリと一緒に終わらないので、ここで止める
    func applicationWillTerminate(_ notification: Notification) {
        speedTestScheduler.stop()
        storageScanScheduler.stop()
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

    /**
     `NetworkSource` は揺れ止めの記録を、検出の Source は取り直しをまたぐ履歴を持つので、1つずつ作って持ち続ける。
     NetworkSource は計測の状態を読み、スケジューラは最新の接続チェックを条件にして終わったら一覧を取り直すので互いを参照し合う。
     スケジューラだけを作り終えてから入れて輪を解く。ストレージの走査も同じ形で結ぶ。
     負荷とストレージも、テストやプレビューで ps や du を走らせないよう、ネットワークと同じくここで足す
     */
    private static func makeLiveModels() -> Models {
        let schedulerReference = WeakReference<SpeedTestScheduler>()
        let scannerReference = WeakReference<StorageScanScheduler>()
        let networkSource = NetworkSource(speedTest: { @MainActor in
            schedulerReference.object?.snapshot ?? .idle
        })
        let storageSource = StorageSource(scan: { @MainActor in
            scannerReference.object?.lastScan
        })
        let discovery = ItemDiscovery(sources: ItemDiscovery.standardSources + [networkSource, SystemLoadSource(), storageSource])
        let appModel = AppModel(discover: { await discovery.items() })
        let scheduler = SpeedTestScheduler(
            conditions: { SpeedTestScheduler.Conditions(latestCheck: await networkSource.latestCheck()) },
            onFinish: { [weak appModel] in
                await appModel?.refresh()
            }
        )
        let storageScanScheduler = StorageScanScheduler(onFinish: { [weak appModel] in
            await appModel?.refresh()
        })
        schedulerReference.object = scheduler
        scannerReference.object = storageScanScheduler
        return Models(appModel: appModel, speedTestScheduler: scheduler, storageScanScheduler: storageScanScheduler)
    }
}

/// アプリの起動に合わせて作り、ウインドウと設定で共有する状態の組
@MainActor
private struct Models {
    let appModel: AppModel
    let speedTestScheduler: SpeedTestScheduler
    let storageScanScheduler: StorageScanScheduler
}

/// 互いを参照し合う部品を、作り終えてから結ぶための入れ物
@MainActor
private final class WeakReference<Object: AnyObject> {
    weak var object: Object?
}
