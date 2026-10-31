import Foundation
import Synchronization
import Testing
@testable import Breaker

struct MonitoredAppSourceTests {
    @Test func mergesInstalledAndRunningApps() async throws {
        let directory = try TemporaryDirectory()
        let applications = directory.url
        try makeApp(applications.appending(path: "AudioPin.app"), bundleID: "com.example.AudioPin")
        try makeApp(applications.appending(path: "FeedReader.app"), bundleID: "com.example.feedreader")
        try makeApp(applications.appending(path: "Breaker.app"), bundleID: "dev.wata.Breaker")
        try makeApp(applications.appending(path: "Safari.app"), bundleID: "com.apple.Safari")
        // Mac で動く iPhone アプリは WrappedBundle がリンクで、その先に本体がある。常駐させるものではないので除外する
        let wrapped = applications.appending(path: "Planner.app")
        try makeApp(wrapped.appending(path: "Wrapper/PlannerMobile.app"), bundleID: "com.example.planner", infoPath: "Info.plist")
        try FileManager.default.createSymbolicLink(atPath: wrapped.appending(path: "WrappedBundle").path(percentEncoded: false), withDestinationPath: "Wrapper/PlannerMobile.app")
        try FileManager.default.createDirectory(at: applications.appending(path: "Utilities"), withIntermediateDirectories: true)

        let archived = URL(filePath: "/Users/me/Developer/AudioPin/build/Release/AudioPin.app")
        let running = [
            RunningApp(bundleID: "com.example.AudioPin", bundleURL: archived, name: "AudioPin"),
            RunningApp(bundleID: "com.example.feedreader", bundleURL: applications.appending(path: "FeedReader.app"), name: "FeedReader"),
            RunningApp(bundleID: "dev.wata.Breaker", bundleURL: applications.appending(path: "Breaker.app"), name: "Breaker"),
            RunningApp(bundleID: "dev.wata.BreakerTests", bundleURL: nil, name: nil),
            RunningApp(
                bundleID: "com.example.planner.widget",
                bundleURL: URL(filePath: "/private/var/folders/x/Wrapper/PlannerMobile.app/PlugIns/Widget.appex"),
                name: "Planner"
            ),
            RunningApp(
                bundleID: "com.example.scorecard",
                bundleURL: URL(filePath: "/private/var/folders/x/d/Wrapper/Scorecard.app"),
                name: "Scorecard Pro"
            ),
            RunningApp(bundleID: "com.apple.finder", bundleURL: nil, name: "Finder"),
        ]
        // 選んでいない Safari・Finder は出さない。自分自身は選ばれていても出さない
        let source = MonitoredAppSource(
            bundleIDs: {
                [
                    "com.example.AudioPin",
                    "com.example.feedreader",
                    "dev.wata.Breaker",
                    "com.example.planner",
                    "com.example.planner.widget",
                    "com.example.scorecard",
                ]
            },
            applicationsDirectory: applications,
            runningApps: { running }
        )
        let items = try await source.items().reduce(into: [String: MonitoredItem]()) { $0[$1.name] = $1 }

        #expect(Set(items.keys) == ["AudioPin", "FeedReader"])
        #expect(items["AudioPin"]?.status == .warning(reason: "Running from outside /Applications", note: archived.path(percentEncoded: false)))
        #expect(items["FeedReader"]?.status == .running)
        #expect(items["FeedReader"]?.id == "monitoredApp:com.example.feedreader")
        guard case .monitoredApp(let audioPin) = items["AudioPin"]?.detail else {
            Issue.record("AudioPin がアプリとして検出されていない")
            return
        }
        #expect(audioPin.appURL == archived)
        #expect(audioPin.isRunning)
    }

    /// /Applications にない自作アプリでも、起動していれば拾う
    @Test func includesRunningAppNotInstalled() async throws {
        let directory = try TemporaryDirectory()
        let running = [RunningApp(bundleID: "com.example.debug", bundleURL: URL(filePath: "/tmp/Debug.app"), name: "Debug")]
        let items = try await MonitoredAppSource(bundleIDs: { ["com.example.debug"] }, applicationsDirectory: directory.url, runningApps: { running }).items()
        #expect(items.map(\.name) == ["Debug"])
        #expect(items.first?.status.isAbnormal == true)
    }

    /// 起動していなくても /Applications にある Mac アプリは「未起動」として出す
    @Test func listsInstalledAppNotRunningAsInactive() async throws {
        let directory = try TemporaryDirectory()
        try makeApp(directory.url.appending(path: "FeedReader.app"), bundleID: "com.example.feedreader")
        let items = try await MonitoredAppSource(bundleIDs: { ["com.example.feedreader"] }, applicationsDirectory: directory.url, runningApps: { [] }).items()
        #expect(items.map(\.status) == [.inactive(reason: "Not running")])
    }

    /// 初期値は何も選んでいない。そのときは /Applications にあっても起動中でも出さない
    @Test func listsNothingUntilAppsAreSelected() async throws {
        let directory = try TemporaryDirectory()
        try makeApp(directory.url.appending(path: "Example.app"), bundleID: "com.example.app")
        let running = [RunningApp(bundleID: "com.example.app", bundleURL: directory.url.appending(path: "Example.app"), name: "Example")]
        let items = try await MonitoredAppSource(bundleIDs: { [] }, applicationsDirectory: directory.url, runningApps: { running }).items()
        #expect(items.isEmpty)
    }

    /// 選んだ Bundle ID だけを、接頭辞に関係なく出す
    @Test func listsOnlySelectedBundleIDs() async throws {
        let directory = try TemporaryDirectory()
        try makeApp(directory.url.appending(path: "Example.app"), bundleID: "com.example.app")
        try makeApp(directory.url.appending(path: "Other.app"), bundleID: "com.example.other")
        let items = try await MonitoredAppSource(bundleIDs: { ["com.example.app"] }, applicationsDirectory: directory.url, runningApps: { [] }).items()
        #expect(items.map(\.id) == ["monitoredApp:com.example.app"])
    }

    /// 起動中は同じ Source を使い続けるので、設定で選び直した内容が次の `items()` から効く
    @Test func reflectsSelectionChangedAfterInit() async throws {
        let directory = try TemporaryDirectory()
        try makeApp(directory.url.appending(path: "Example.app"), bundleID: "com.example.app")
        let selected = Mutex<[String]>([])
        let source = MonitoredAppSource(bundleIDs: { selected.withLock { $0 } }, applicationsDirectory: directory.url, runningApps: { [] })
        #expect(try await source.items().isEmpty)

        selected.withLock { $0 = ["com.example.app"] }
        #expect(try await source.items().map(\.id) == ["monitoredApp:com.example.app"])
    }

    @Test func readsSelectedBundleIDsFromDefaults() throws {
        let defaults = try IsolatedDefaults()
        #expect(MonitoredAppSource.selectedBundleIDs(in: defaults.userDefaults).isEmpty)
        defaults.userDefaults.set(["com.example.b", "com.example.a"], forKey: MonitoredAppSource.bundleIDsKey)
        #expect(MonitoredAppSource.selectedBundleIDs(in: defaults.userDefaults) == ["com.example.b", "com.example.a"])
    }

    private func makeApp(_ url: URL, bundleID: String, infoPath: String = "Contents/Info.plist") throws {
        let infoURL = url.appending(path: infoPath)
        try FileManager.default.createDirectory(at: infoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0).write(to: infoURL)
    }
}
