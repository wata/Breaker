import Foundation

/// 全種類の Source を並行に走らせ、一覧に出す順（種類 → 状態 → 名前）で返す
struct ItemDiscovery: Sendable {
    private let sources: [any ItemSource]

    init(sources: [any ItemSource] = [LaunchAgentSource(), CronSource(), FolderActionSource(), SwiftBarSource(), MonitoredAppSource()]) {
        self.sources = sources
    }

    func items() async -> [MonitoredItem] {
        let items = await withTaskGroup(of: [MonitoredItem].self) { group in
            for source in sources {
                group.addTask {
                    await Self.items(from: source)
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
        return Self.sorted(items)
    }

    /**
     節の中は、異常をすぐ見つけられるよう失敗・要確認を上に寄せ（`ItemStatus.sortOrder`）、同じ状態の中は名前順にする。
     Source を並行に走らせるので届く順は毎回違う。取り直すたびに行が入れ替わらないよう、最後は一意な id で決める
     （同じラベルが `~/Library/LaunchAgents` と `/Library/LaunchAgents` にあると名前が並ぶ）
     */
    static func sorted(_ items: [MonitoredItem]) -> [MonitoredItem] {
        let kindOrder = Dictionary(uniqueKeysWithValues: MonitoredItem.Kind.allCases.enumerated().map { ($1, $0) })
        return items.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return kindOrder[lhs.kind, default: 0] < kindOrder[rhs.kind, default: 0]
            }
            if lhs.status.sortOrder != rhs.status.sortOrder {
                return lhs.status.sortOrder < rhs.status.sortOrder
            }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    /**
     1種類の失敗で他の種類まで消えないよう、失敗はその種類の警告1件に置き換える。
     エラー文（`Domain …` など）はサイドバーの行には長く読みにくいので、理由は短い説明にし、エラー文は補足に回して詳細とツールチップにだけ出す
     */
    private static func items(from source: any ItemSource) async -> [MonitoredItem] {
        do {
            return try await source.items()
        } catch {
            return [sourceFailure(of: source.kind, message: error.localizedDescription)]
        }
    }

    static func sourceFailure(of kind: MonitoredItem.Kind, message: String) -> MonitoredItem {
        MonitoredItem(
            key: "sourceFailure",
            name: String(localized: "Can't Get \(kind.title)", comment: "Name of the item shown when a whole kind of item couldn't be discovered, e.g. Can't Get Folder Actions"),
            status: .warning(
                reason: String(localized: "Check failed", comment: "Reason of the item shown when a whole kind of item couldn't be discovered. The error message is shown separately"),
                note: message
            ),
            detail: .sourceFailure(kind)
        )
    }
}
