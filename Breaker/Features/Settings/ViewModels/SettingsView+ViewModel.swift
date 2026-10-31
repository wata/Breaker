import AppKit

extension SettingsView {
    /// 監視するアプリの一覧の1行。アプリが消えていても選んだことは残し、Bundle ID で見せる
    struct MonitoredApp: Identifiable, Hashable {
        let bundleID: String
        let name: String
        let appURL: URL?

        var id: String {
            bundleID
        }
    }

    /// テストで LaunchServices に問い合わせずに済むよう、Bundle ID からアプリの場所を引く処理を差し替えられるようにする
    typealias AppLocator = @MainActor (String) -> URL?

    @MainActor
    @Observable
    final class ViewModel {
        private(set) var loginItemStatus: LoginItemStatus
        var failureMessage: String?
        private(set) var monitoredApps: [MonitoredApp]

        @ObservationIgnored
        private let loginItem: any LoginItemManaging
        @ObservationIgnored
        private let defaults: UserDefaults
        /// 監視するアプリを選び直したら、次の定期チェックを待たずに一覧へ反映する
        @ObservationIgnored
        private let refreshItems: @MainActor () async -> Void

        init(
            loginItem: any LoginItemManaging = LoginItemService(),
            defaults: UserDefaults = .standard,
            locateApp: @escaping AppLocator = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
            refreshItems: @escaping @MainActor () async -> Void = {}
        ) {
            self.loginItem = loginItem
            self.defaults = defaults
            self.refreshItems = refreshItems
            loginItemStatus = loginItem.status
            monitoredApps = MonitoredAppSource.selectedBundleIDs(in: defaults).map { Self.monitoredApp(bundleID: $0, appURL: locateApp($0)) }
        }

        /// 許可待ちも「登録した」側に数え、トグルを戻すと登録を取り消せるようにする
        var launchesAtLogin: Bool {
            loginItemStatus != .disabled
        }

        /// 失敗しても状態は OS に問い合わせ直し、トグルを実際の登録状態に合わせる
        func setLaunchesAtLogin(_ isOn: Bool) {
            do {
                if isOn {
                    try loginItem.register()
                } else {
                    try loginItem.unregister()
                }
                failureMessage = nil
            } catch {
                failureMessage = error.localizedDescription
            }
            reloadStatus()
        }

        /// システム設定で許可・取り消しされても通知は来ないので、アプリに戻ってきたときに読み直す
        func reloadStatus() {
            loginItemStatus = loginItem.status
        }

        func openSystemSettings() {
            loginItem.openSystemSettings()
        }

        /// 選んだ順のまま末尾に足す。Bundle ID の読めないもの（Mac で動く iPhone アプリなど）・自分自身・選択済みは飛ばす
        func addMonitoredApps(at urls: [URL]) async {
            var selected = Set(monitoredApps.map(\.bundleID))
            let added = urls.compactMap { url -> MonitoredApp? in
                guard
                    let bundleID = MonitoredAppSource.bundleID(of: url),
                    bundleID != MonitoredAppSource.ownBundleID,
                    selected.insert(bundleID).inserted
                else {
                    return nil
                }
                return Self.monitoredApp(bundleID: bundleID, appURL: url)
            }
            guard !added.isEmpty else { return }
            monitoredApps += added
            await saveMonitoredApps()
        }

        func removeMonitoredApp(_ app: MonitoredApp) async {
            monitoredApps.removeAll { $0.id == app.id }
            await saveMonitoredApps()
        }

        private func saveMonitoredApps() async {
            defaults.set(monitoredApps.map(\.bundleID), forKey: MonitoredAppSource.bundleIDsKey)
            await refreshItems()
        }

        private static func monitoredApp(bundleID: String, appURL: URL?) -> MonitoredApp {
            MonitoredApp(
                bundleID: bundleID,
                // 表示名は Finder の「拡張子を表示」の設定によって `.app` が付くので外す
                name: appURL.map { FileManager.default.displayName(atPath: $0.path(percentEncoded: false)).replacing(/\.app$/, with: "") } ?? bundleID,
                appURL: appURL
            )
        }
    }
}
