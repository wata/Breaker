import Foundation

extension SettingsView {
    @MainActor
    @Observable
    final class ViewModel {
        private(set) var loginItemStatus: LoginItemStatus
        var failureMessage: String?

        /// scheduler は自動で測るかを判定するたびに UserDefaults から読み直すので、保存するだけで次の判定から効く
        var speedTestInterval: SpeedTestInterval {
            didSet {
                SpeedTestInterval.save(speedTestInterval, in: defaults)
            }
        }

        private(set) var locationStatus: LocationAuthorizationStatus
        private(set) var showsNetworkName: Bool

        @ObservationIgnored
        private let loginItem: any LoginItemManaging
        @ObservationIgnored
        private let locationAuthorization: any LocationAuthorizing
        @ObservationIgnored
        private let defaults: UserDefaults
        /// ネットワーク名の表示を切り替えたら、次の定期チェックを待たずに一覧へ反映する
        @ObservationIgnored
        private let refreshItems: @MainActor () async -> Void

        init(
            loginItem: any LoginItemManaging = LoginItemService(),
            locationAuthorization: any LocationAuthorizing = LocationAuthorization(),
            defaults: UserDefaults = .standard,
            refreshItems: @escaping @MainActor () async -> Void = {}
        ) {
            self.loginItem = loginItem
            self.locationAuthorization = locationAuthorization
            self.defaults = defaults
            self.refreshItems = refreshItems
            loginItemStatus = loginItem.status
            locationStatus = locationAuthorization.status
            showsNetworkName = defaults.bool(forKey: WiFiReader.showsNetworkNameKey)
            speedTestInterval = SpeedTestInterval.selected(in: defaults)
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
            locationStatus = locationAuthorization.status
        }

        func openSystemSettings() {
            loginItem.openSystemSettings()
        }

        /// オンにしたときだけ位置情報の許可を求める。拒否されてもオンのまま残し、システム設定で許可すれば次のチェックから名前が出る
        func setShowsNetworkName(_ isOn: Bool) async {
            showsNetworkName = isOn
            defaults.set(isOn, forKey: WiFiReader.showsNetworkNameKey)
            if
                isOn,
                locationStatus == .notDetermined
            {
                locationStatus = await locationAuthorization.requestAuthorization()
            }
            await refreshItems()
        }

        func openLocationSettings() {
            locationAuthorization.openSystemSettings()
        }
    }
}
