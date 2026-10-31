import Foundation

/**
 `note` は Breaker が理由に添える補足（予定の日時・無いパス・ログのエラー行など）。理由は短い本文にして、補足は分けて持つ。
 詳細の見出しでは理由だけを出して補足を副行に回し、通知とツールチップでは理由の後に括弧で続けて出す。
 外から受け取ったエラー文は括弧があっても補足に分けないよう、文字列を解析せず作るときに分けて持たせる
 */
enum ItemStatus: Hashable, Sendable {
    /// 直近の実行が成功している、または想定どおり待機している
    case ok
    case running
    /// ジョブの仕事ができていない（終了コードが 0 以外・走っていない・必要なファイルが無い・未ロード・ログにエラー）
    case failed(reason: String, note: String? = nil)
    /// 未ロード・無効化など、意図して止めている状態
    case inactive(reason: String, note: String? = nil)
    /// 動いてはいるが確認が必要な状態（実行パスが /Applications 外など）
    case warning(reason: String, note: String? = nil)
    /// launchctl で状態を読めなかった。利用者が直せない閲覧のみのジョブなので、異常とも正常とも言わない
    case unknown(reason: String, note: String? = nil)

    /// 通知と Dock バッジの対象。意図して止めているものは数えない
    var isAbnormal: Bool {
        switch self {
        case .failed, .warning:
            true

        case .ok, .running, .inactive, .unknown:
            false
        }
    }

    var isFailed: Bool {
        if case .failed = self {
            true
        } else {
            false
        }
    }

    /**
     サイドバーの節の中の並び（失敗 → 要確認 → 正常・実行中 → 停止・未確認）。
     正常と実行中を分けると、ジョブが走り出すたびに行が動いてしまうので同じ順にする
     */
    var sortOrder: Int {
        switch self {
        case .failed:
            0

        case .warning:
            1

        case .ok, .running:
            2

        case .inactive, .unknown:
            3
        }
    }

    /// 補足を除いた理由。正常・実行中は nil
    var reason: String? {
        switch self {
        case .ok, .running:
            nil

        case .failed(let reason, _), .inactive(let reason, _), .warning(let reason, _), .unknown(let reason, _):
            reason
        }
    }

    var note: String? {
        switch self {
        case .ok, .running:
            nil

        case .failed(_, let note), .inactive(_, let note), .warning(_, let note), .unknown(_, let note):
            note
        }
    }
}
