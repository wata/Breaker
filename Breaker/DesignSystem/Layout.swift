import SwiftUI

/// サイドバーと詳細の幅は、フィードリーダーによくある3ペインから記事リストを抜いた構成に合わせている
enum Layout {
    static let minWindowWidth: CGFloat = 760
    static let minWindowHeight: CGFloat = 480
    /// ラベルの長い launchd ジョブ（`com.example.daily-sales-report` など）が1行に収まる幅
    static let sidebarMinWidth: CGFloat = 240
    static let sidebarIdealWidth: CGFloat = 280
    static let detailMinWidth: CGFloat = 420
    /// ログ末尾の枠の高さの上限。短いログは中身の高さまで縮め、これを超えたら 15 行ほどを見せて残りはスクロールで追う
    static let logMaxHeight: CGFloat = 240
    /// スケジュール編集シート。曜日ボタン7つと時刻・削除ボタンが1行に収まる幅
    static let sheetWidth: CGFloat = 520
    /// 時刻1行と保存後のスケジュール（2行）がスクロールせずに見える高さ
    static let sheetMinHeight: CGFloat = 600
    /// 時・分・日・間隔の数値入力。3桁まで見える幅
    static let numberFieldWidth: CGFloat = 44
    /// 設定ウインドウ。ログイン項目の説明文が2行ほどに収まる幅
    static let settingsWidth: CGFloat = 460
    /// ネットワークの経路図のつなぎ目の線の太さ。状態の色が読み取れ、記号より目立たない太さ
    static let routeLineWidth: CGFloat = 2
    /// 届いていない・測っていないつなぎ目の破線。色だけに頼らず、切れていることを形でも見せる
    static let routeLineDash: [CGFloat] = [3, 3]
    /// 速度の推移のグラフ。7日分の上下が読み取れ、詳細の他の節を押し出しすぎない高さ
    static let speedChartHeight: CGFloat = 160
    /// 速度の推移のグラフの線。経路図の線と同じく、色と形が読み取れる細さ
    static let chartLineWidth: CGFloat = 2
    /// 上りの線の破線。色だけに頼らず下りと見分けられるようにする
    static let chartLineDash: [CGFloat] = [3, 3]
}
