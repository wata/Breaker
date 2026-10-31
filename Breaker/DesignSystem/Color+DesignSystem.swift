import SwiftUI

/// 文字色は `.primary` / `.secondary` / `.tertiary` を直接使い、ここにはアプリ固有の色だけを置く
extension Color {
    /**
     ジョブの状態を示すドットの色。ダークモードでも見分けられるようシステム色を使う。
     色だけで意味を負わせず、文言やアイコンと並べて出す
     */
    enum Status {
        static let ok = Color.green
        static let warning = Color.orange
        static let failure = Color.red
        /// 停止中・未ロードなど、異常ではないが動いていない状態。異常色と競わない無彩色にする
        static let inactive = Color(nsColor: .tertiaryLabelColor)
    }

    /// 一度だけの設定の案内（ログイン項目の許可待ち）に添える記号。異常の色（`Status`）と競わないよう、橙ではなく黄にする
    static let caution = Color.yellow

    /// ログ本文のエラーらしい行に敷く地。文字は本文の色のまま読めるよう、失敗の色をごく薄くする
    static let logErrorLine = Status.failure.opacity(0.18)
}


/// 色そのものではなく、見つからない・使えないものを薄く見せる度合い
enum Opacity {
    /// 設定の、見つからないアプリの汎用アイコン
    static let dimmed = 0.4
}
