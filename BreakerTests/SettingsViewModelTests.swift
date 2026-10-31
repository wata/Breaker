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

    /// 選んだ順に並べ、見つからないアプリは Bundle ID のまま出す
    @Test func loadsSelectedMonitoredApps() throws {
        let defaults = try IsolatedDefaults()
        defaults.userDefaults.set(["com.example.b", "com.example.missing"], forKey: MonitoredAppSource.bundleIDsKey)
        let viewModel = SettingsView.ViewModel(
            loginItem: StubLoginItem(status: .disabled),
            defaults: defaults.userDefaults,
            locateApp: { $0 == "com.example.b" ? URL(filePath: "/Applications/B.app") : nil }
        )
        #expect(viewModel.monitoredApps.map(\.bundleID) == ["com.example.b", "com.example.missing"])
        #expect(viewModel.monitoredApps.map(\.appURL) == [URL(filePath: "/Applications/B.app"), nil])
        #expect(viewModel.monitoredApps.last?.name == "com.example.missing")
    }

    @Test func monitoredAppsAreEmptyByDefault() throws {
        let defaults = try IsolatedDefaults()
        let viewModel = SettingsView.ViewModel(loginItem: StubLoginItem(status: .disabled), defaults: defaults.userDefaults)
        #expect(viewModel.monitoredApps.isEmpty)
    }

    /// 選択済み・自分自身・Bundle ID の読めないものは足さない。足したら保存して一覧を取り直す
    @Test func addingMonitoredAppsSavesAndRefreshes() async throws {
        let defaults = try IsolatedDefaults()
        let directory = try TemporaryDirectory()
        let ownBundleID = try #require(MonitoredAppSource.ownBundleID)
        let example = try makeApp(directory.url.appending(path: "Example.app"), bundleID: "com.example.app")
        let other = try makeApp(directory.url.appending(path: "Other.app"), bundleID: "com.example.other")
        let own = try makeApp(directory.url.appending(path: "Breaker.app"), bundleID: ownBundleID)
        let broken = directory.url.appending(path: "Broken.app")
        var refreshCount = 0
        let viewModel = SettingsView.ViewModel(
            loginItem: StubLoginItem(status: .disabled),
            defaults: defaults.userDefaults,
            locateApp: { _ in nil },
            refreshItems: { refreshCount += 1 }
        )

        await viewModel.addMonitoredApps(at: [other, own, broken, example, other])

        #expect(viewModel.monitoredApps.map(\.bundleID) == ["com.example.other", "com.example.app"])
        #expect(viewModel.monitoredApps.map(\.appURL) == [other, example])
        #expect(MonitoredAppSource.selectedBundleIDs(in: defaults.userDefaults) == ["com.example.other", "com.example.app"])
        #expect(refreshCount == 1)

        // 何も増えなければ保存も取り直しもしない
        await viewModel.addMonitoredApps(at: [example, own])
        #expect(viewModel.monitoredApps.count == 2)
        #expect(refreshCount == 1)
    }

    @Test func removingMonitoredAppSavesAndRefreshes() async throws {
        let defaults = try IsolatedDefaults()
        defaults.userDefaults.set(["com.example.a", "com.example.b"], forKey: MonitoredAppSource.bundleIDsKey)
        var refreshCount = 0
        let viewModel = SettingsView.ViewModel(
            loginItem: StubLoginItem(status: .disabled),
            defaults: defaults.userDefaults,
            locateApp: { _ in nil },
            refreshItems: { refreshCount += 1 }
        )

        await viewModel.removeMonitoredApp(try #require(viewModel.monitoredApps.first))

        #expect(viewModel.monitoredApps.map(\.bundleID) == ["com.example.b"])
        #expect(MonitoredAppSource.selectedBundleIDs(in: defaults.userDefaults) == ["com.example.b"])
        #expect(refreshCount == 1)
    }

    private func makeApp(_ url: URL, bundleID: String) throws -> URL {
        let infoURL = url.appending(path: "Contents/Info.plist")
        try FileManager.default.createDirectory(at: infoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0).write(to: infoURL)
        return url
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
