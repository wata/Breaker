import Foundation
import Testing
@testable import Breaker

/// 英語をキーにした文言から、日本語の訳が実際に引けることを確かめる。訳は Localizable.xcstrings にある
struct LocalizationTests {
    private static let english = Locale(identifier: "en_US")
    private static let japanese = Locale(identifier: "ja_JP")

    private static func ja(_ resource: LocalizedStringResource) -> String {
        String(localized: resource, language: japanese)
    }

    @Test func appHasJapaneseLocalization() {
        #expect(Bundle.main.developmentLocalization == "en")
        #expect(Bundle.main.localizations.contains("ja"))
    }

    /// 状態の理由は検出のたびに作るので、作るときと同じ補間のキーで引く
    @Test func reasonsHaveJapaneseTranslations() {
        #expect(Self.ja("Exit code \(Int32(1))") == "終了コード 1")
        #expect(Self.ja("Terminated by signal \(Int32(9))") == "シグナル 9 で終了")
        #expect(Self.ja("Not loaded") == "未ロード")
        #expect(Self.ja(LocalizedStringResource("Disabled", comment: "Status of a launchd job or folder action that is turned off")) == "無効")
        #expect(Self.ja(LocalizedStringResource("Folder not found", comment: "Reason shown for a folder action whose folder doesn't exist")) == "対象フォルダがありません")
        #expect(Self.ja(LocalizedStringResource("it may not be mounted", comment: "Note in parentheses after Folder not found")) == "未マウントの可能性")
        #expect(Self.ja("Can't read status") == "状態を読めません")
        #expect(Self.ja(LocalizedStringResource("Error in log", comment: "Reason of an item whose log has an error line. The line itself is shown separately")) == "ログにエラー")
        #expect(Self.ja("Running from outside /Applications") == "/Applications 外から起動しています")
        #expect(
            Self.ja(LocalizedStringResource("Didn't run as scheduled", comment: "Reason of a job that didn't run at its scheduled time. The time is shown separately"))
                == "予定どおり実行されていません"
        )
    }

    @Test func statusAndActionNamesHaveJapaneseTranslations() {
        #expect(Self.ja(LocalizedStringResource("Healthy", comment: "Status of an item that is working as expected")) == "正常")
        #expect(Self.ja(LocalizedStringResource("Needs Attention", comment: "Status of an item that is running but should be checked, and the title of the sidebar section that gathers failed items and items that need attention")) == "要確認")
        #expect(Self.ja("\("失敗") (\("終了コード 1"))") == "失敗（終了コード 1）")
        #expect(Self.ja(LocalizedStringResource("Run Now", comment: "Action that runs a launchd job immediately")) == "今すぐ実行")
        #expect(Self.ja("Show \("rename.scpt") in Finder") == "rename.scpt を Finder で表示")
        #expect(Self.ja(LocalizedStringResource("Home", comment: "Filter option: launchd jobs that run your scripts in your home folder")) == "ホーム")
        #expect(Self.ja("User Agent") == "ユーザーエージェント")
        #expect(Self.ja(LocalizedStringResource("hour", comment: "Unit after the interval number field in the schedule editor when the number is 1")) == "時間ごと")
        #expect(Self.ja(LocalizedStringResource("minute", comment: "Unit after the interval number field in the schedule editor when the number is 1")) == "分ごと")
        #expect(Self.ja("\("ユーザーエージェント") · \("終了コード 1")") == "ユーザーエージェント · 終了コード 1")
    }

    /// 前回・次回の日時はロケールの書式に従う。日本語は英語ベースにする前と同じ「10/31(土) 3:30」
    @Test func runDatesFollowLocale() throws {
        let calendar = Calendar.current
        let last = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 3, minute: 30)))
        let next = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 3, minute: 30)))
        #expect(MonitoredItem.format(next, locale: Self.japanese) == "10/31(土) 3:30")
        #expect(MonitoredItem.format(next, locale: Self.english) == "Sat, 10/31, 3:30\u{202F}AM")
        // 昨日・今日・明日でなければ、言葉にせず日付で出す
        let later = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12)))
        #expect(
            MonitoredItem.runSummary(lastRun: last, nextRun: next, lastRunStyle: .absolute, now: later, calendar: calendar, locale: Self.japanese)
                == "前回 10/30(金) 3:30 · 次回 10/31(土) 3:30"
        )
        #expect(
            MonitoredItem.runSummary(lastRun: last, nextRun: next, lastRunStyle: .absolute, now: later, calendar: calendar, locale: Self.english)
                == "Last: Fri, 10/30, 3:30\u{202F}AM · Next: Sat, 10/31, 3:30\u{202F}AM"
        )
    }

    /// 昨日・今日・明日は、人が言うのと同じく言葉で出す。時刻の書き方はロケールに従う
    @Test func runDatesUseRelativeDayWords() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        func date(_ day: Int, _ hour: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour)))
        }
        let now = try date(1, 10)
        func format(_ date: Date, _ locale: Locale) -> String {
            MonitoredItem.formatRunDate(date, now: now, calendar: calendar, locale: locale)
        }
        #expect(format(try date(1, 11), Self.english) == "Today 11:00\u{202F}AM")
        #expect(format(try date(2, 9), Self.english) == "Tomorrow 9:00\u{202F}AM")
        #expect(format(try date(1, 0) - 1, Self.english) == "Yesterday 11:59\u{202F}PM")
        #expect(format(try date(3, 9), Self.english) == "Tue, 11/3, 9:00\u{202F}AM")
        #expect(format(try date(1, 11), Self.japanese) == "今日 11:00")
        #expect(format(try date(2, 9), Self.japanese) == "明日 9:00")
        #expect(format(try date(1, 0) - 1, Self.japanese) == "昨日 23:59")
        #expect(format(try date(3, 9), Self.japanese) == "11/3(火) 9:00")
        #expect(
            MonitoredItem.runSummary(lastRun: try date(1, 9), nextRun: try date(2, 9), lastRunStyle: .absolute, now: now, calendar: calendar, locale: Self.japanese)
                == "前回 今日 9:00 · 次回 明日 9:00"
        )
    }

    /**
     サイドバーの2行目の前回。英語はラベルの後の値を大文字始まりにそろえ、次回の「Tomorrow 9:00 AM」と同じ書き方にする。
     要確認の節で添える種類と節の見出しにも訳がある
     */
    @Test func sidebarTextFollowsLocale() throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 10)))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        func last(_ date: Date, _ locale: Locale) -> String {
            MonitoredItem.lastRunText(date, style: .relative, now: now, calendar: calendar, locale: locale)
        }
        #expect(last(yesterday, Self.english) == "Last: Yesterday")
        #expect(last(now.addingTimeInterval(-600), Self.english) == "Last: 10 min. ago")
        #expect(last(yesterday, Self.japanese) == "前回 昨日")
        #expect(last(now.addingTimeInterval(-600), Self.japanese) == "前回 10 分前")
        let tomorrow = try #require(calendar.date(byAdding: .hour, value: 23, to: now))
        #expect(MonitoredItem.nextRunText(tomorrow, now: now, calendar: calendar, locale: Self.japanese) == "次回 明日 9:00")

        #expect(Self.ja("cron Jobs") == "cron ジョブ")
        #expect(Self.ja(LocalizedStringResource("Check failed", comment: "Reason of the item shown when a whole kind of item couldn't be discovered. The error message is shown separately")) == "確認に失敗")
        #expect(Self.ja("\("launchd") · \("終了コード 1")") == "launchd · 終了コード 1")
        #expect(Self.ja("Approve Breaker in Login Items to open it at login.") == "ログイン時に開くには、ログイン項目で Breaker を許可してください。")
        #expect(Self.ja("Not Found") == "見つかりません")
    }
}
