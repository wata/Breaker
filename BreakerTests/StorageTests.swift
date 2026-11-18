import Foundation
import Testing
@testable import Breaker

struct StorageTests {
    private static func usage(available: Int64, capacity: Int64 = 1_000_000_000_000) -> StorageUsage {
        StorageUsage(capacityBytes: capacity, availableBytes: available, scan: nil)
    }

    /// 空きが 10% 未満で要確認、5% 未満で失敗
    @Test func status() {
        #expect(StorageSource.status(of: Self.usage(available: 200_000_000_000)) == .ok)
        #expect(StorageSource.status(of: Self.usage(available: 90_000_000_000)).isAbnormal)
        #expect(!StorageSource.status(of: Self.usage(available: 90_000_000_000)).isFailed)
        #expect(StorageSource.status(of: Self.usage(available: 40_000_000_000)).isFailed)
    }

    @Test func sourceReturnsOneItem() async throws {
        let source = StorageSource(
            readVolume: { .init(capacityBytes: 1_000_000_000_000, availableBytes: 500_000_000_000) },
            scan: { StorageScan.sample }
        )
        let items = try await source.items()
        #expect(items.count == 1)
        #expect(items.first?.status == .ok)
        #expect(items.first?.detail == .storage(StorageUsage(capacityBytes: 1_000_000_000_000, availableBytes: 500_000_000_000, scan: StorageScan.sample)))
    }

    /// 読めないフォルダがあって終了コードが 1 でも、`du -sk` の各行を足す
    @Test func totalBytesOfDiskUsageOutput() {
        let text = "1024\t/Users/me/.npm\n2048\t/Users/me/.gradle\ndu: /Users/me/x: Permission denied\n"
        #expect(DiskUsage.parseTotalBytes(text) == 3 * 1024 * 1024)
    }

    /// 前回の結果と比べて増えた分を持ち、大きい順に並べる。無いフォルダは測らず、大きさ 0 の場所は出さない
    @Test func scanComparesWithPrevious() async throws {
        let home = try TemporaryDirectory()
        for path in ["Library/Caches", "Library/Developer/Xcode/DerivedData"] {
            try FileManager.default.createDirectory(at: home.url.appending(path: path), withIntermediateDirectories: true)
        }
        let homePath = home.url.path(percentEncoded: false).trimmingSuffix("/")
        let shell = StubShell { call in
            guard call.executable == "/usr/bin/du" else {
                return ShellOutput(status: 0, stdout: "", stderr: "")
            }
            let kilobytes = call.arguments.last?.contains("DerivedData") == true ? 3_000_000 : 1_000_000
            return ShellOutput(status: 0, stdout: "\(kilobytes)\t\(call.arguments.last ?? "")\n", stderr: "")
        }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = StorageScan(
            date: date.addingTimeInterval(-3600),
            previousDate: nil,
            locations: [.init(location: .derivedData, path: "", bytes: 1_000_000_000, previousBytes: nil)]
        )
        let scan = await DiskUsage(shell: shell, home: home.url, now: { date }).scan(previous: previous)

        #expect(scan.locations.map(\.location) == [.derivedData, .caches])
        #expect(scan.locations[0].growthBytes == Int64(3_000_000 * 1024 - 1_000_000_000))
        #expect(scan.locations[0].path == "\(homePath)/Library/Developer/Xcode/DerivedData")
        #expect(scan.locations[1].growthBytes == nil)
        #expect(scan.previousDate == previous.date)
        let duCalls = shell.calls.filter { $0.executable == "/usr/bin/du" }
        #expect(duCalls.count == 2)
    }

    /// du が時間切れなどで測れなかった場所は、0 として消さずに前回の結果を残す
    @Test func failedMeasurementKeepsPrevious() async throws {
        let home = try TemporaryDirectory()
        try FileManager.default.createDirectory(at: home.url.appending(path: "Library/Caches"), withIntermediateDirectories: true)
        let previousLocation = StorageScan.Location(location: .caches, path: "/x", bytes: 5_000_000_000, previousBytes: 4_000_000_000)
        let previous = StorageScan(date: .distantPast, previousDate: nil, locations: [previousLocation])
        let scan = await DiskUsage(shell: ThrowingShell(error: ShellError.timedOut(executable: "/usr/bin/du")), home: home.url).scan(previous: previous)
        #expect(scan.locations == [previousLocation])
    }

    /// 要確認の節では種類を理由の前に添えるが、名前が種類の名前そのもの（ストレージ）なら同じ語を繰り返さない
    @Test func needsAttentionRowDoesNotRepeatTheKind() {
        let item = MonitoredItem.sampleStorage
        #expect(item.rowDetail(now: .now, showsKind: true) == item.status.reason)
    }

    /// 1 GB 未満の増減は揺れとみなして言わない
    @Test func growthText() {
        let english = Locale(identifier: "en_US")
        let grown = StorageScan.Location(location: .caches, path: "", bytes: 13_000_000_000, previousBytes: 1_000_000_000)
        let stable = StorageScan.Location(location: .caches, path: "", bytes: 1_500_000_000, previousBytes: 1_000_000_000)
        #expect(grown.growthText(locale: english) == "+12 GB")
        #expect(stable.growthText(locale: english) == nil)
        #expect(Self.usage(available: 38_000_000_000).summary(locale: english) == "38 GB free")
    }

    /// 走査の結果は起動し直しても残り、次の走査の比べる相手になる。間隔が来るまでは走らせない
    @MainActor
    @Test func scannerRunsWhenDue() async throws {
        let defaults = try IsolatedDefaults()
        let counter = ScanCounter()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let scanner = StorageScanScheduler(diskUsage: counter, defaults: defaults.userDefaults, now: { [now] in now })
        await scanner.scanIfDue()
        #expect(await counter.count == 1)
        await scanner.scanIfDue()
        #expect(await counter.count == 1)

        now = now.addingTimeInterval(StorageScanScheduler.interval)
        let reopened = StorageScanScheduler(diskUsage: counter, defaults: try #require(UserDefaults(suiteName: defaults.suiteName)), now: { [now] in now })
        #expect(reopened.lastScan != nil)
        await reopened.scanIfDue()
        #expect(await counter.count == 2)
        #expect(await counter.lastPrevious != nil)
    }
}

private actor ScanCounter: StorageScanning {
    private(set) var count = 0
    private(set) var lastPrevious: StorageScan?

    func scan(previous: StorageScan?) async -> StorageScan {
        count += 1
        lastPrevious = previous
        return StorageScan(date: Date(timeIntervalSince1970: 1_800_000_000), previousDate: previous?.date, locations: [])
    }
}
