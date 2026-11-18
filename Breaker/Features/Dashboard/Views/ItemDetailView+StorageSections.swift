import SwiftUI

extension ItemDetailView {
    /**
     ストレージの詳細。主役は空きが減ったときの通知で、ここでは「何が膨らんだか」を指すことに絞る（利用者の判断）。
     場所の中身の内訳は作らず、大きい場所の上位と前回から増えた分を見せ、Finder で開けるようにする。
     容量のバーは上位の場所ごとに色を分け、一覧の行の頭に同じ色の点を付けて、バーのどこが何かを結ぶ（利用者の判断）
     */
    struct StorageSections: View {
        let usage: StorageUsage
        /// 走査の結果と走査中かは、項目の更新を待たずに見せるため直接観測する
        let scheduler: StorageScanScheduler
        let isLocked: Bool
        let perform: (ItemAction) -> Void

        var body: some View {
            let locations = scheduler.lastScan?.topLocations ?? []

            Section {
                FreeSpaceFigure(usage: usage, locations: locations)
            }

            Section {
                ForEach(Array(locations.enumerated()), id: \.element.location) { index, location in
                    LocationRow(location: location, color: Color.StorageBar.locations[index], isLocked: isLocked, perform: perform)
                }

                if
                    scheduler.lastScan == nil,
                    !scheduler.isScanning
                {
                    Text("Locations that often grow, such as Xcode DerivedData and caches, are measured every few hours.")
                        .foregroundStyle(.secondary)
                }

                // 走査は数分かかるので、止まっていると思われないよう時間がかかることも言う
                if scheduler.isScanning {
                    HStack(spacing: Spacing.tight) {
                        ProgressView()
                            .controlSize(.small)

                        Text("Scanning… This can take a few minutes.")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Largest Folders")
            } footer: {
                // 場所の行と同じ形にすると7つ目の場所に見えるので、一覧の外に補足として出す。「2時間前」が古びないよう分ごとに書き直す
                if let scan = scheduler.lastScan {
                    TimelineView(.everyMinute) { context in
                        Text("Scanned \(MonitoredItem.relativeDateText(scan.date, now: context.date))", comment: "Footer of the storage locations, e.g. Scanned 2 hr. ago")
                            .font(.Base.regular)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /**
     `38 GB / 1 TB`。数字だけを大きくし、その下に何が場所を取っているかの内訳のバーを置く。
     空きが少ないことは見出しの状態が言うので、ここでは状態の色と記号を重ねない。橙は一覧の「増えた分」だけに使う
     */
    struct FreeSpaceFigure: View {
        let usage: StorageUsage
        /// 一覧に並べる上位の場所。バーの色の順は一覧の行と同じ
        let locations: [StorageScan.Location]

        var body: some View {
            let available = StorageUsage.bytesText(usage.availableBytes)
            let capacity = String(localized: "of \(StorageUsage.bytesText(usage.capacityBytes))", comment: "After the free space of the startup disk, e.g. 38 GB of 1 TB")
            VStack(alignment: .leading, spacing: Spacing.tight) {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text("Available")
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: Spacing.micro) {
                        Text(available)
                            .font(.Display.value)
                            .textSelection(.enabled)

                        Text(capacity)
                            .foregroundStyle(.secondary)
                    }
                }

                UsageBar(segments: UsageBar.segments(of: usage, locations: locations))

                HStack(spacing: Spacing.standard) {
                    LegendItem(color: Color.StorageBar.other, title: String(localized: "Everything Else", comment: "Storage bar legend: used space outside the listed folders, such as the system and apps"))

                    LegendItem(color: Color.StorageBar.available, title: String(localized: "Available"))
                }
                .font(.Base.regular)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, Spacing.micro)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Available"))
            .accessibilityValue([available, capacity].formatted(.list(type: .and, width: .narrow)))
        }
    }

    /// 起動ディスクの内訳。上位の場所、それ以外の使用中、空きの順に左から並べる
    struct UsageBar: View {
        struct Segment: Identifiable {
            let id: String
            let bytes: Int64
            let color: Color
        }

        let segments: [Segment]

        var body: some View {
            let total = max(segments.reduce(0) { $0 + $1.bytes }, 1)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(segments) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: geometry.size.width * CGFloat(segment.bytes) / CGFloat(total))
                    }
                }
            }
            .frame(height: Layout.storageBarHeight)
            .clipShape(.capsule)
        }

        /// 一覧に出ない分は「その他」にまとめる。走査がまだ無ければ使用中と空きの2つだけ
        static func segments(of usage: StorageUsage, locations: [StorageScan.Location]) -> [Segment] {
            let used = max(usage.capacityBytes - usage.availableBytes, 0)
            let listed = locations.enumerated().map { index, location in
                Segment(id: location.location.rawValue, bytes: location.bytes, color: Color.StorageBar.locations[index])
            }
            let other = max(used - listed.reduce(0) { $0 + $1.bytes }, 0)
            return listed + [
                Segment(id: "other", bytes: other, color: Color.StorageBar.other),
                Segment(id: "available", bytes: usage.availableBytes, color: Color.StorageBar.available),
            ]
        }
    }

    /// バーの色の説明。一覧の行は自分の点で説明するので、ここでは一覧に出ない分と空きだけ
    struct LegendItem: View {
        let color: Color
        let title: String

        var body: some View {
            HStack(spacing: Spacing.micro) {
                Circle()
                    .fill(color)
                    .frame(width: Layout.legendDotSize, height: Layout.legendDotSize)

                Text(title)
            }
        }
    }

    /// 場所の名前と大きさを1行に置く。前回から目立って増えていれば、何が膨らんだかが分かるよう大きさの前に増えた分を添える
    struct LocationRow: View {
        let location: StorageScan.Location
        /// 内訳のバーでこの場所を塗った色
        let color: Color
        let isLocked: Bool
        let perform: (ItemAction) -> Void

        var body: some View {
            LabeledContent {
                HStack(spacing: Spacing.tight) {
                    if let growth = location.growthText() {
                        Text(growth)
                            .foregroundStyle(Color.Status.warning)
                            .monospacedDigit()
                            .help(Text("Grew since the previous scan", comment: "Tooltip of the growth shown next to a storage location"))
                    }

                    Text(StorageUsage.bytesText(location.bytes))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    RevealButton(url: URL(filePath: location.path), isLocked: isLocked, help: location.path.abbreviatingHome, perform: perform)
                }
            } label: {
                LegendItem(color: color, title: location.location.title)
            }
        }
    }
}

extension StorageScan {
    /// 詳細に並べる場所の数。何が膨らんだかを指すのに足りる数で、内訳のバーの色（`Color.StorageBar.locations`）と同じ数
    static let listedLocationCount = 6

    var topLocations: [Location] {
        Array(locations.prefix(Self.listedLocationCount))
    }
}
