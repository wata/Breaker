import SwiftUI

/**
 nested enum + weight variant 構成。サイズは iOS ではなく macOS の
 テキストスタイル既定値（caption 10 / subheadline 11 / body 13 / title2 17）に合わせている
 */
extension Font {
    // MARK: - Typography Scale

    /// 10pt - Captions, metadata labels (サイドバー下端の最終更新、シートや設定の注記)
    enum Small {
        static let regular = Font.system(size: 10, weight: .regular)
    }

    /**
     サイドバーの行の2行目以降（理由・前回／次回の実行）。システム設定の「サイドバーのアイコンのサイズ」に追従させる。

     1行目の名前（フォント指定なし）は小 11pt / 中 13pt / 大 15pt で描かれる（`.sidebar` の List に
     `\.sidebarRowSize` を入れ、名前と `.system(size:)` の文字幅を比べて測った）。`.subheadline` などの
     テキストスタイルは行の大きさに追従しない（同じ方法で3つとも同じ大きさだった）ので、固定の pt を返す。
     中で 11pt としていた大きさを基準に、名前との比（11/13）を保って整数に丸めた（小 9.3 → 9、大 12.7 → 13）
     */
    enum SidebarDetail {
        static func regular(for rowSize: SidebarRowSize) -> Font {
            switch rowSize {
            case .small: .system(size: 9, weight: .regular)
            case .medium: .system(size: 11, weight: .regular)
            case .large: .system(size: 13, weight: .regular)
            @unknown default: .system(size: 11, weight: .regular)
            }
        }
    }

    /// サイドバーの行の状態の記号。1行目の名前（`SidebarDetail` の注記のとおり 小 11pt / 中 13pt / 大 15pt）と同じ大きさにして、行の大きさに追従させる
    enum SidebarStatus {
        static func regular(for rowSize: SidebarRowSize) -> Font {
            switch rowSize {
            case .small: .system(size: 11, weight: .regular)
            case .medium: .system(size: 13, weight: .regular)
            case .large: .system(size: 15, weight: .regular)
            @unknown default: .system(size: 13, weight: .regular)
            }
        }
    }

    /// 11pt - Secondary text
    enum Base {
        static let regular = Font.system(size: 11, weight: .regular)
    }

    /// 13pt - Primary body text (macOS .body)
    enum Body {
        static let regular = Font.system(size: 13, weight: .regular)
    }

    /// 17pt - Title text (詳細の概要の状態の行。失敗の通知から来たときに、ログより先に目に入る強さにする)
    enum Title {
        static let semiBold = Font.system(size: 17, weight: .semibold)
    }

    // MARK: - Numeric Fonts

    /// 数字専用。monospacedDigit を焼き込み、時刻や件数の幅を揃える
    enum Number {
        static func regular(of size: CGFloat) -> Font {
            .system(size: size, weight: .regular)
            .monospacedDigit()
        }
    }

    // MARK: - Code

    /// ログ末尾・実行コマンド・パスの表示。桁を揃えて読めるよう等幅にする
    enum Mono {
        static let regular = Font.system(size: 11, weight: .regular, design: .monospaced)
    }
}
