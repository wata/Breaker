import Foundation

/// 定期チェックで見つけた、通知で知らせる異常
enum AbnormalAlert: Hashable, Sendable {
    /// 起動直後のチェックで既に異常だった項目が複数あるとき。1件ずつ出すと通知が溢れるのでまとめる
    case summary([MonitoredItem])
    case item(MonitoredItem)

    /**
     直前のチェック結果と比べ、新しく異常になった項目だけを返す。異常の理由が変わったもの、新しく見つかって異常なものも含める。
     同じ異常が続いている項目と、異常から戻った項目は知らせない（戻ったことは Dock バッジの数で伝わる）。ホームのジョブ以外の launchd ジョブは知らせない。
     `previous` が nil のときは起動直後の初回で、比べる相手がないので今の異常をまとめて1回だけ知らせる
     */
    static func alerts(from previous: [MonitoredItem]?, to current: [MonitoredItem]) -> [AbnormalAlert] {
        let abnormal = current.filter(\.isReportedAbnormal)
        guard let previous else {
            return abnormal.count > 1 ? [.summary(abnormal)] : abnormal.map(AbnormalAlert.item)
        }
        let previousStatuses = Dictionary(previous.map { ($0.id, $0.status) }) { first, _ in first }
        return abnormal
            .filter { previousStatuses[$0.id] != $0.status }
            .map(AbnormalAlert.item)
    }
}
