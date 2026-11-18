import Foundation

/// 起動ディスクの空きを読み、最新の走査結果と合わせて項目を1つ返す
struct StorageSource: ItemSource {
    /// 走査のスケジューラは MainActor にあるので、最新の結果を値の写しで受け取る
    typealias ScanProvider = @Sendable () async -> StorageScan?
    typealias VolumeReader = @Sendable () throws -> Volume

    struct Volume: Hashable, Sendable {
        let capacityBytes: Int64
        let availableBytes: Int64
    }

    /// 空きがこれを下回ったら要確認。ログやバックアップの書き込みが失敗し始める前に知らせる
    static let warningShare = 0.10
    /// 空きがこれを下回ったら失敗。macOS のアップデートや一時ファイルの書き込みがもう通らない
    static let failureShare = 0.05

    let kind = MonitoredItem.Kind.storage

    private let readVolume: VolumeReader
    private let scan: ScanProvider

    init(readVolume: @escaping VolumeReader = Self.readHomeVolume, scan: @escaping ScanProvider = { nil }) {
        self.readVolume = readVolume
        self.scan = scan
    }

    func items() async throws -> [MonitoredItem] {
        let volume = try readVolume()
        let usage = StorageUsage(capacityBytes: volume.capacityBytes, availableBytes: volume.availableBytes, scan: await scan())
        return [MonitoredItem(key: "volume", name: kind.title, status: Self.status(of: usage), detail: .storage(usage))]
    }

    static func status(of usage: StorageUsage) -> ItemStatus {
        switch usage.availableShare {
        case ..<failureShare:
            .failed(reason: String(localized: "Almost out of storage", comment: "Reason of the storage item when less than 5% of the startup disk is free"))

        case ..<warningShare:
            .warning(reason: String(localized: "Storage is running low", comment: "Reason of the storage item when less than 10% of the startup disk is free"))

        default:
            .ok
        }
    }

    /// ホームのあるボリューム（起動ディスクのデータ領域）。Finder の「空き」と同じく、パージできる領域も空きに含める
    @Sendable static func readHomeVolume() throws -> Volume {
        let values = try FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return Volume(capacityBytes: Int64(values.volumeTotalCapacity ?? 0), availableBytes: values.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
