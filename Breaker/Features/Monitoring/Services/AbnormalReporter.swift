import AppKit
import UserNotifications

/// テストで本物の通知や Dock バッジを出さずに、知らせた内容を記録できるよう切り出す
@MainActor
protocol AbnormalReporting {
    func post(_ alerts: [AbnormalAlert]) async
    func showBadge(count: Int)
}

/// macOS の通知センターと Dock で異常を知らせる
@MainActor
struct AbnormalReporter: AbnormalReporting {
    /// 通知をタップしたときに選ぶ項目の id。まとめの通知には入れない
    nonisolated static let itemIDKey = "itemID"

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /**
     許可を求めるのは初回だけ OS が出す。断られていても通知が出ないだけなので、結果は使わない
     通知センターを使うアプリの Dock バッジは通知のバッジ許可に従うため、`.badge` を求めないと `showBadge` が表示されない
     */
    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func post(_ alerts: [AbnormalAlert]) async {
        for alert in alerts {
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: Self.content(for: alert), trigger: nil)
            try? await center.add(request)
        }
    }

    func showBadge(count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? count.formatted() : nil
    }

    private static func content(for alert: AbnormalAlert) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.sound = .default
        switch alert {
        case .summary(let items):
            content.title = String(localized: "\(items.count) Items Have Issues", comment: "Notification title when several items have issues. Title case without ending punctuation")
            content.body = items.map(\.name).formatted(.list(type: .and))

        case .item(let item):
            content.title = String(localized: "\(item.name): \(item.status.title)", comment: "Notification title: item name and its status, e.g. backup: Failed")
            content.body = item.status.fullReason ?? ""
            content.userInfo = [itemIDKey: item.id]
        }
        return content
    }
}
