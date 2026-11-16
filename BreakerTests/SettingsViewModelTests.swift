import Foundation
import Testing
@testable import Breaker

@MainActor
struct SettingsViewModelTests {
    @Test func turningOnRegistersAndReloadsStatus() {
        let loginItem = StubLoginItem(status: .disabled, statusAfterRegister: .requiresApproval)
        let viewModel = SettingsView.ViewModel(loginItem: loginItem)
        #expect(!viewModel.launchesAtLogin)

        viewModel.setLaunchesAtLogin(true)

        #expect(loginItem.calls == ["register"])
        #expect(viewModel.loginItemStatus == .requiresApproval)
        #expect(viewModel.launchesAtLogin)
        #expect(viewModel.failureMessage == nil)
    }

    @Test func turningOffUnregisters() {
        let loginItem = StubLoginItem(status: .enabled)
        let viewModel = SettingsView.ViewModel(loginItem: loginItem)

        viewModel.setLaunchesAtLogin(false)

        #expect(loginItem.calls == ["unregister"])
        #expect(viewModel.loginItemStatus == .disabled)
    }

    /// 登録に失敗したらトグルを実際の状態（未登録）に戻し、理由を出す
    @Test func failureKeepsActualStatusAndShowsMessage() {
        let loginItem = StubLoginItem(status: .disabled, failure: CocoaError(.fileNoSuchFile))
        let viewModel = SettingsView.ViewModel(loginItem: loginItem)

        viewModel.setLaunchesAtLogin(true)

        #expect(!viewModel.launchesAtLogin)
        #expect(viewModel.failureMessage != nil)
    }

    @Test func reloadPicksUpApprovalInSystemSettings() {
        let loginItem = StubLoginItem(status: .requiresApproval)
        let viewModel = SettingsView.ViewModel(loginItem: loginItem)

        loginItem.status = .enabled
        viewModel.reloadStatus()

        #expect(viewModel.loginItemStatus == .enabled)
    }

    @Test func speedTestIntervalDefaultsToEveryHour() throws {
        let defaults = try IsolatedDefaults()
        let viewModel = SettingsView.ViewModel(loginItem: StubLoginItem(status: .disabled), defaults: defaults.userDefaults)

        #expect(viewModel.speedTestInterval == .oneHour)
    }

    /// scheduler が読むのと同じ場所に書く
    @Test func choosingSpeedTestIntervalSavesIt() throws {
        let defaults = try IsolatedDefaults()
        let viewModel = SettingsView.ViewModel(loginItem: StubLoginItem(status: .disabled), defaults: defaults.userDefaults)

        viewModel.speedTestInterval = .manual

        #expect(SpeedTestInterval.selected(in: defaults.userDefaults) == .manual)
        let reopened = SettingsView.ViewModel(loginItem: StubLoginItem(status: .disabled), defaults: defaults.userDefaults)
        #expect(reopened.speedTestInterval == .manual)
    }

    /// 前の版で保存した、今は無い値が入っていても既定に戻す
    @Test func unknownSpeedTestIntervalFallsBackToDefault() throws {
        let defaults = try IsolatedDefaults()
        defaults.userDefaults.set("fiveMinutes", forKey: SpeedTestInterval.key)
        let viewModel = SettingsView.ViewModel(loginItem: StubLoginItem(status: .disabled), defaults: defaults.userDefaults)

        #expect(viewModel.speedTestInterval == SpeedTestInterval.defaultValue)
    }

    @Test func everySpeedTestIntervalHasTitle() {
        for interval in SpeedTestInterval.allCases {
            #expect(!interval.title.isEmpty)
        }
    }

    /// オンにしたときだけ許可を求め、次の定期チェックを待たずに一覧を取り直す
    @Test func turningOnNetworkNameAsksForLocationAndRefreshes() async throws {
        let defaults = try IsolatedDefaults()
        let location = StubLocationAuthorization(status: .notDetermined, answer: .authorized)
        var refreshCount = 0
        let viewModel = SettingsView.ViewModel(
            loginItem: StubLoginItem(status: .enabled),
            locationAuthorization: location,
            defaults: defaults.userDefaults,
            refreshItems: { refreshCount += 1 }
        )
        #expect(!viewModel.showsNetworkName)

        await viewModel.setShowsNetworkName(true)

        #expect(viewModel.showsNetworkName)
        #expect(defaults.userDefaults.bool(forKey: WiFiReader.showsNetworkNameKey))
        #expect(viewModel.locationStatus == .authorized)
        #expect(location.requestCount == 1)
        #expect(refreshCount == 1)
    }

    /// 拒否されてもオンのまま残す（システム設定で許可すれば名前が出る）。オフにするときは尋ねない
    @Test func deniedLocationKeepsToggleAndTurningOffDoesNotAsk() async throws {
        let defaults = try IsolatedDefaults()
        let location = StubLocationAuthorization(status: .notDetermined, answer: .denied)
        let viewModel = SettingsView.ViewModel(loginItem: StubLoginItem(status: .enabled), locationAuthorization: location, defaults: defaults.userDefaults)

        await viewModel.setShowsNetworkName(true)
        #expect(viewModel.showsNetworkName)
        #expect(viewModel.locationStatus == .denied)

        await viewModel.setShowsNetworkName(false)
        #expect(!defaults.userDefaults.bool(forKey: WiFiReader.showsNetworkNameKey))
        #expect(location.requestCount == 1)
    }

    /// システム設定で許可を変えても知らせは来ないので、アプリに戻ったときの読み直しで追従する
    @Test func reloadingPicksUpLocationChangedInSystemSettings() {
        let location = StubLocationAuthorization(status: .denied, answer: .denied)
        let viewModel = SettingsView.ViewModel(loginItem: StubLoginItem(status: .enabled), locationAuthorization: location, defaults: .preview)

        location.status = .authorized
        viewModel.reloadStatus()

        #expect(viewModel.locationStatus == .authorized)
    }

}

/// 実際の `SMAppService` には触れず、呼ばれた操作だけを記録する
@MainActor
private final class StubLoginItem: LoginItemManaging {
    var status: LoginItemStatus
    private(set) var calls = [String]()
    private let statusAfterRegister: LoginItemStatus
    private let failure: (any Error)?

    init(status: LoginItemStatus, statusAfterRegister: LoginItemStatus = .enabled, failure: (any Error)? = nil) {
        self.status = status
        self.statusAfterRegister = statusAfterRegister
        self.failure = failure
    }

    func register() throws {
        calls.append("register")
        if let failure {
            throw failure
        }
        status = statusAfterRegister
    }

    func unregister() throws {
        calls.append("unregister")
        if let failure {
            throw failure
        }
        status = .disabled
    }

    func openSystemSettings() {
        calls.append("openSystemSettings")
    }
}


/// 実際の `CLLocationManager` には触れず、尋ねられたら決めておいた答えを返す
@MainActor
private final class StubLocationAuthorization: LocationAuthorizing {
    var status: LocationAuthorizationStatus
    private let answer: LocationAuthorizationStatus

    init(status: LocationAuthorizationStatus, answer: LocationAuthorizationStatus) {
        self.status = status
        self.answer = answer
    }

    private(set) var requestCount = 0

    func requestAuthorization() async -> LocationAuthorizationStatus {
        requestCount += 1
        status = answer
        return answer
    }

    func openSystemSettings() {}
}
