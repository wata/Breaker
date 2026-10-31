import SwiftUI

extension ItemStatus {
    var title: String {
        switch self {
        case .ok:
            String(localized: "Healthy", comment: "Status of an item that is working as expected")

        case .running:
            String(localized: "Running", comment: "Status of an item that is running now")

        case .failed:
            String(localized: "Failed", comment: "Status of an item whose last run failed")

        case .inactive:
            String(localized: "Stopped", comment: "Status of an item that was stopped on purpose")

        case .warning:
            String(localized: "Needs Attention", comment: "Status of an item that is running but should be checked, and the title of the sidebar section that gathers failed items and items that need attention")

        case .unknown:
            String(localized: "Unknown", comment: "Status of a read-only item whose state couldn't be read")
        }
    }

    /// 通知・ツールチップに出す理由の全文。補足があれば括弧で続ける
    var fullReason: String? {
        reason.map { reason in
            note.map { Self.parenthesized(reason, $0) } ?? reason
        }
    }

    /**
     詳細ヘッダーの見出し。状態は隣のシンボルの色と形で伝わるので、理由があれば理由だけを出す（補足は副行に回す）。
     失敗の理由は「終了コード 1」のように数字だけで失敗と読めないことがあるので、状態名を残して理由を括弧に入れる
     */
    var summary: String {
        switch self {
        case .failed(let reason, _):
            Self.parenthesized(title, reason)

        default:
            reason ?? title
        }
    }

    /// 日本語では全角の括弧にする
    private static func parenthesized(_ text: String, _ note: String) -> String {
        String(localized: "\(text) (\(note))", comment: "Text followed by a parenthetical, e.g. Failed (Exit code 1) or Folder not found (it may not be mounted)")
    }

    /// 状態の色を付けて出すシンボル。色だけで状態を伝えないよう、状態ごとに形も変える。サイドバーの行と詳細ヘッダーで同じものを使う
    var systemImage: String {
        switch self {
        case .ok:
            "checkmark.circle.fill"

        case .running:
            "play.circle.fill"

        case .failed:
            "xmark.circle.fill"

        case .inactive:
            "pause.circle.fill"

        case .warning:
            Self.widestSystemImage

        case .unknown:
            "questionmark.circle.fill"
        }
    }

    /// 状態の記号のうち、いちばん幅の広いもの。サイドバーの行で記号の枠の幅をそろえるのに使う
    static let widestSystemImage = "exclamationmark.triangle.fill"

    var isInactive: Bool {
        if case .inactive = self {
            true
        } else {
            false
        }
    }

    var color: Color {
        switch self {
        case .ok, .running:
            .Status.ok

        case .failed:
            .Status.failure

        // 異常ではないので、異常色と競わない停止中と同じ無彩色にする（形はシンボルで見分ける）
        case .inactive, .unknown:
            .Status.inactive

        case .warning:
            .Status.warning
        }
    }
}

extension MonitoredItem {
    /**
     サイドバーの行と詳細ヘッダーの状態の記号。起動していないアプリは一時停止しているのではなく止まっているので、一時停止の記号を使わない。
     launchd ジョブの無効・未ロードは、停止の操作（一時停止の絵）で休ませたものなので一時停止の記号のままにする
     */
    var statusSystemImage: String {
        if case (.inactive, .monitoredApp) = (status, detail) {
            "stop.circle.fill"
        } else {
            status.systemImage
        }
    }
}
