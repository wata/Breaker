import Foundation
import Testing
@testable import Breaker

struct ScheduleSummaryTests {
    typealias Entry = Schedule.CalendarEntry

    private static let english = Locale(identifier: "en_US")
    private static let japanese = Locale(identifier: "ja_JP")

    /// 型推論が重くなりすぎるので、引数の表は型を明示して外に出す。英語の時刻の AM/PM の前は狭いノーブレークスペース
    private static let calendarCases: [([Entry], [String], [String])] = [
        ([Entry(minute: 0, hour: 9, weekday: 1), Entry(minute: 0, hour: 9, weekday: 2), Entry(minute: 0, hour: 9, weekday: 3),
          Entry(minute: 0, hour: 9, weekday: 4), Entry(minute: 0, hour: 9, weekday: 5)], ["Weekdays at 9:00\u{202F}AM"], ["平日 9:00"]),
        ([Entry(minute: 0, hour: 11, day: 1)], ["Monthly on day 1 at 11:00\u{202F}AM"], ["毎月1日 11:00"]),
        ([Entry(minute: 30, hour: 3)], ["Every day at 3:30\u{202F}AM"], ["毎日 3:30"]),
        ([Entry(minute: 15)], ["Every hour at minute 15"], ["毎時15分"]),
        ([Entry()], ["Every minute"], ["毎分"]),
        ([Entry(hour: 9)], ["Every day, every minute during hour 9"], ["毎日 9時台の毎分"]),
        ([Entry(minute: 0, hour: 10, weekday: 0), Entry(minute: 0, hour: 10, weekday: 6)], ["Weekends at 10:00\u{202F}AM"], ["週末 10:00"]),
        // 0 と 7 はどちらも日曜
        ([Entry(minute: 0, hour: 8, weekday: 7)], ["Sundays at 8:00\u{202F}AM"], ["毎週日曜 8:00"]),
        ([Entry(minute: 0, hour: 8, weekday: 5), Entry(minute: 0, hour: 8, weekday: 1), Entry(minute: 0, hour: 8, weekday: 3)],
         ["Mon, Wed, Fri at 8:00\u{202F}AM"], ["月・水・金 8:00"]),
        ([Entry(minute: 0, hour: 8, weekday: 1), Entry(minute: 0, hour: 8)], ["Every day at 8:00\u{202F}AM"], ["毎日 8:00"]),
        ((0...6).map { Entry(minute: 0, hour: 8, weekday: $0) }, ["Every day at 8:00\u{202F}AM"], ["毎日 8:00"]),
        ([Entry(minute: 0, hour: 9, weekday: 1), Entry(minute: 0, hour: 18, weekday: 1)],
         ["Mondays at 9:00\u{202F}AM", "Mondays at 6:00\u{202F}PM"], ["毎週月曜 9:00", "毎週月曜 18:00"]),
        ([Entry(minute: 0, hour: 0, day: 1, month: 1)], ["Jan 1 at 12:00\u{202F}AM"], ["1月1日 0:00"]),
        ([Entry(minute: 0, hour: 9, month: 4)], ["Every day in Apr at 9:00\u{202F}AM"], ["4月の毎日 9:00"]),
        ([Entry(minute: 0, hour: 9, day: 1, weekday: 1)], ["Day 1 or Mondays at 9:00\u{202F}AM"], ["1日または毎週月曜 9:00"]),
        ([Entry(minute: 15, weekday: 6)], ["Saturdays, every hour at minute 15"], ["毎週土曜 毎時15分"]),
    ]

    @Test(arguments: calendarCases)
    func calendar(entries: [Entry], english: [String], japanese: [String]) {
        let schedule = Schedule(calendarEntries: entries)
        #expect(schedule.summaryLines(locale: Self.english) == english)
        // 日本語の訳が引け、英語ベースにする前と同じ見た目になる
        #expect(schedule.summaryLines(locale: Self.japanese) == japanese)
    }

    /// スケジュール編集で時の範囲にしたものは時ごとのエントリになるので、1行にまとめる。訳はまだないので英語だけ確かめる
    private static let hourRangeCases: [([Entry], [String])] = [
        ((7...23).map { Entry(minute: 0, hour: $0) }, ["Every day, every hour from 7:00\u{202F}AM to 11:00\u{202F}PM"]),
        ((9...17).flatMap { hour in (1...5).map { Entry(minute: 30, hour: hour, weekday: $0) } }, ["Weekdays, every hour from 9:30\u{202F}AM to 5:30\u{202F}PM"]),
        ([Entry(minute: 0, hour: 7), Entry(minute: 0, hour: 9)], ["Every day at 7:00\u{202F}AM", "Every day at 9:00\u{202F}AM"]),
    ]

    @Test(arguments: hourRangeCases)
    func contiguousHoursReadAsRange(entries: [Entry], english: [String]) {
        #expect(Schedule(calendarEntries: entries).summaryLines(locale: Self.english) == english)
    }

    @Test func combinesAllTriggersInOrder() {
        let schedule = Schedule(
            calendarEntries: [Entry(minute: 0, hour: 9)],
            interval: 1800,
            runAtLoad: true,
            keepAlive: true,
            watchPaths: ["~/Downloads", "~/Desktop"]
        )
        #expect(schedule.summaryLines(locale: Self.english) == [
            "Every day at 9:00\u{202F}AM", "Every 30 minutes", "At login", "Always running (KeepAlive)", "Watching files: ~/Downloads, ~/Desktop",
        ])
        #expect(schedule.summaryLines(locale: Self.japanese) == ["毎日 9:00", "30分ごと", "ログイン時", "常駐（KeepAlive）", "ファイル監視: ~/Downloads, ~/Desktop"])
    }

    @Test func emptyScheduleSaysNoTrigger() {
        #expect(Schedule().summaryLines(locale: Self.english) == ["No launch triggers"])
        #expect(Schedule().summaryLines(locale: Self.japanese) == ["起動条件なし"])
    }

    /// 英語は1のとき数を省く（複数形の訳が効いている）
    @Test(arguments: [
        (1, "Every second", "1秒ごと"),
        (45, "Every 45 seconds", "45秒ごと"),
        (60, "Every minute", "1分ごと"),
        (1800, "Every 30 minutes", "30分ごと"),
        (5400, "Every 90 minutes", "90分ごと"),
        (3600, "Every hour", "1時間ごと"),
        (7200, "Every 2 hours", "2時間ごと"),
        (86400, "Every day", "1日ごと"),
    ])
    func interval(seconds: Int, english: String, japanese: String) {
        #expect(Schedule.intervalText(seconds: seconds, locale: Self.english) == english)
        #expect(Schedule.intervalText(seconds: seconds, locale: Self.japanese) == japanese)
    }

    /// 既定はスキームで固定した英語。テストを動かす Mac の言語に左右されない
    @Test func defaultsToTestLanguage() {
        #expect(Schedule(calendarEntries: [Entry(minute: 30, hour: 7)]).summaryLines == ["Every day at 7:30\u{202F}AM"])
    }
}
