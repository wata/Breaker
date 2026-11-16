import Foundation

/// 監視対象を種類ごとに検出する。`ItemDiscovery` が全種類をまとめて呼ぶ
protocol ItemSource: Sendable {
    var kind: MonitoredItem.Kind { get }
    func items() async throws -> [MonitoredItem]
}

extension String {
    /// plist や defaults の値は `~/` 始まりのことがある。テストでホームを差し替えられるよう、ホームは引数で受け取る
    func expandingTilde(home: URL) -> String {
        guard hasPrefix("~/") || self == "~" else {
            return self
        }
        return home.path(percentEncoded: false).trimmingSuffix("/") + dropFirst()
    }

    /// `expandingTilde(home:)` の逆。理由の文言に出すパスを、テストで差し替えたホームでも `~` に縮める
    func abbreviatingTilde(home: URL) -> String {
        let homePath = home.path(percentEncoded: false).trimmingSuffix("/")
        return isPath(under: homePath) ? "~" + dropFirst(homePath.count) : self
    }

    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }

    /// `root` 自身かその配下か。`~/dev` が `~/devtools` に一致しないよう、区切りの `/` まで含めて比べる
    func isPath(under root: String) -> Bool {
        self == root || hasPrefix(root.trimmingSuffix("/") + "/")
    }
}

extension Sequence where Element: Hashable {
    /// 最初に出た順のまま重複を除く。標準出力と標準エラーを同じファイルに出す設定で、同じパスを2回読まないために使う
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
