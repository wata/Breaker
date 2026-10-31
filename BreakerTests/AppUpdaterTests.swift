import Testing
@testable import Breaker

@MainActor
struct AppUpdaterTests {
    /// テストホストでは Sparkle を始めないので、更新の確認を走らせず、メニューの項目も押せない
    @Test func doesNotStartInTestHost() {
        #expect(AppEnvironment.isIsolated())
        #expect(!AppUpdater().canCheckForUpdates)
    }
}
