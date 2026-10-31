import AppKit
import Testing
@testable import Breaker

@MainActor
struct AppDelegateTests {
    @Test func keepsRunningAfterLastWindowClosed() {
        #expect(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(.shared) == false)
    }
}
