import Foundation
import Testing
@testable import Breaker

struct AppEnvironmentTests {
    /// このテスト自体がテストホストで動いているので、実際の環境でも隔離と判定されること
    @Test func currentTestHostIsIsolated() {
        #expect(AppEnvironment.isIsolated())
    }

    @Test func detectsTestHostAndPreviews() {
        #expect(AppEnvironment.isIsolated(["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        #expect(AppEnvironment.isIsolated(["XCODE_RUNNING_FOR_PREVIEWS": "1"]))
        #expect(!AppEnvironment.isIsolated(["HOME": "/Users/me"]))
    }

    /// 起動引数が無ければ従来どおり。テストホストも引数なしで起動されるので、実際の環境でも見本データにならない
    @Test func sampleDataIsOffWithoutArgument() throws {
        let defaults = try IsolatedDefaults()
        #expect(!AppEnvironment.usesSampleData(defaults.userDefaults))
        #expect(!AppEnvironment.usesSampleData())
    }

    /// 引数ドメインには `-BreakerSampleData YES` が文字列の "YES" として入る
    @Test func sampleDataIsOnWithArgumentInDebug() throws {
        let defaults = try IsolatedDefaults()
        defaults.userDefaults.set("YES", forKey: AppEnvironment.sampleDataKey)
        #expect(AppEnvironment.usesSampleData(defaults.userDefaults, isDebugBuild: true))
        #expect(AppEnvironment.usesSampleData(defaults.userDefaults) == AppEnvironment.isDebugBuild)
    }

    @Test func sampleDataIsOffInRelease() throws {
        let defaults = try IsolatedDefaults()
        defaults.userDefaults.set("YES", forKey: AppEnvironment.sampleDataKey)
        #expect(!AppEnvironment.usesSampleData(defaults.userDefaults, isDebugBuild: false))
    }
}
