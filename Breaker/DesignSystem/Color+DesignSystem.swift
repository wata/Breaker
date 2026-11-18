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

    /// 速度の下り・上り。大きな数字の矢印とグラフの線で同じ色にして対応を示す。状態の色（緑・橙・赤）と取り違えない色にする
    enum Speed {
        static let download = Color.blue
        static let upload = Color.purple
    }

    /**
     負荷の推移のグラフ。全体の面は背景に退かせ、原因のアプリの線だけを目立たせる。
     線は状態の色（橙・赤）と取り違えないよう青にする。アクセント色は利用者が橙や赤に変えられるので使わない
     */
    enum LoadChart {
        static let total = Color(nsColor: .tertiaryLabelColor)
        static let highlight = Color.blue
    }

    /**
     ストレージの内訳のバーと、一覧の行の頭の点。場所ごとに色を変えてバーと行を結ぶ。
     橙・赤は状態と「増えた分」に使っているので避ける。上位の場所の数（`StorageScan.listedLocationCount`）だけ用意する
     */
    enum StorageBar {
        static let locations: [Color] = [.blue, .purple, .teal, .indigo, .brown, .mint]
        /// 一覧に出ない場所とシステム・アプリなど、測っていない使用中の領域
        static let other = Color(nsColor: .systemGray)
        static let available = Color(nsColor: .quaternaryLabelColor)
    }

    /// 一度だけの設定の案内（ログイン項目の許可待ち）に添える記号。異常の色（`Status`）と競わないよう、橙ではなく黄にする
    static let caution = Color.yellow

    /// ログ本文のエラーらしい行に敷く地。文字は本文の色のまま読めるよう、失敗の色をごく薄くする
    static let logErrorLine = Status.failure.opacity(0.18)
}

/// 色そのものではなく、今の状態を表さない値を退かせる度合い
enum Opacity {
    /// ネットワークが異常なときの前回の速度の推移。原因（経路図・ヘッダー）より先に目に入らないようにする
    static let stale = 0.4
}
