import Foundation
import Testing
@testable import Breaker

struct SidebarFooterTests {
    /// 夏時間のないタイムゾーンに固定し、実行環境に左右されないようにする
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private static let english = Locale(identifier: "en_US")
    private static let japanese = Locale(identifier: "ja_JP")

    /// 2026-10-29 15:30 JST
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 15, minute: 30))!

    @Test(arguments: [
        (0, "Updated just now", "たった今更新"),
        (59, "Updated just now", "たった今更新"),
        // 時計が戻って未来の日時になった場合
        (-120, "Updated just now", "たった今更新"),
        (29 * 60, "Updated 29 min ago", "29分前に更新"),
        (2 * 3600 + 5 * 60, "Updated 2 hr ago", "2時間前に更新"),
    ] as [(TimeInterval, String, String)])
    func lastRefreshTextToday(secondsAgo: TimeInterval, english: String, japanese: String) {
        let date = Self.now.addingTimeInterval(-secondsAgo)
        #expect(SidebarView.Footer.lastRefreshText(date, now: Self.now, calendar: Self.calendar, locale: Self.english) == english)
        #expect(SidebarView.Footer.lastRefreshText(date, now: Self.now, calendar: Self.calendar, locale: Self.japanese) == japanese)
    }

    @Test func lastRefreshTextBeforeToday() {
        let date = Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 9, minute: 5))!
        #expect(SidebarView.Footer.lastRefreshText(date, now: Self.now, calendar: Self.calendar, locale: Self.english) == "Updated Oct 28 at 9:05\u{202F}AM")
        #expect(SidebarView.Footer.lastRefreshText(date, now: Self.now, calendar: Self.calendar, locale: Self.japanese) == "10月28日 9:05に更新")
    }
}
