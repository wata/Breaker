import Foundation

/// launchd plist の起動条件。StartCalendarInterval / StartInterval から次回実行を計算する
struct Schedule: Hashable, Sendable {
    /**
     StartCalendarInterval の1エントリ。launchd と同じく、指定のないキーは「毎回」として扱う。
     weekday は launchd の表記（0 と 7 が日曜）のまま持つ
     */
    struct CalendarEntry: Hashable, Sendable {
        var minute: Int?
        var hour: Int?
        var day: Int?
        var weekday: Int?
        var month: Int?
    }

    var calendarEntries: [CalendarEntry] = []
    /// StartInterval（秒）
    var interval: Int?
    var runAtLoad = false
    /// KeepAlive が true のものだけ。条件付き（辞書）の KeepAlive は止まっていても正常なことがあるので含めない
    var keepAlive = false
    var watchPaths: [String] = []

    /**
     `after` より後の最初の実行時刻。カレンダー指定と StartInterval の両方があれば早い方を返す。
     StartInterval は launchd のロード時刻が取れないので、`lastRun` からの経過で求める（nil なら計算しない）
     */
    func nextRun(after date: Date, lastRun: Date?, calendar: Calendar = .current) -> Date? {
        let calendarRuns = calendarEntries.compactMap { $0.nextRun(after: date, calendar: calendar) }
        let intervalRun = lastRun.flatMap { intervalRun(after: date, lastRun: $0) }
        return (calendarRuns + [intervalRun].compactMap { $0 }).min()
    }

    /// `date` 以前で最後のカレンダーの予定時刻。StartInterval は基準になるロード時刻が取れないので含めない
    func previousRun(atOrBefore date: Date, calendar: Calendar = .current) -> Date? {
        calendarEntries.compactMap { $0.previousRun(atOrBefore: date, calendar: calendar) }.max()
    }

    private func intervalRun(after date: Date, lastRun: Date) -> Date? {
        guard
            let interval,
            interval > 0
        else {
            return nil
        }
        let elapsedIntervals = Int(floor(date.timeIntervalSince(lastRun) / Double(interval)))
        return lastRun.addingTimeInterval(Double(max(elapsedIntervals + 1, 1) * interval))
    }
}

extension Schedule {
    /// plist を `PropertyListSerialization` で読んだ辞書から作る。StartCalendarInterval は辞書1つでも配列でもよい
    init(plist: [String: Any]) {
        let calendarValue = plist["StartCalendarInterval"]
        let calendarDictionaries = (calendarValue as? [[String: Any]])
            ?? (calendarValue as? [String: Any]).map { [$0] }
            ?? []
        calendarEntries = calendarDictionaries.map(CalendarEntry.init(plist:))
        interval = plist["StartInterval"] as? Int
        runAtLoad = plist["RunAtLoad"] as? Bool ?? false
        keepAlive = plist["KeepAlive"] as? Bool ?? false
        watchPaths = plist["WatchPaths"] as? [String] ?? []
    }
}

extension Schedule {
    /**
     `init(plist:)` の逆。StartCalendarInterval と StartInterval だけを差し替え、使わない方のキーは消す。
     RunAtLoad・KeepAlive・WatchPaths を含む他のキーには触れない。
     カレンダー指定が1つなら手書きの plist と同じく辞書で、複数なら配列で書く
     */
    func applyingTimers(to plist: [String: Any]) -> [String: Any] {
        var plist = plist
        switch calendarEntries.count {
        case 0:
            plist["StartCalendarInterval"] = nil

        case 1:
            plist["StartCalendarInterval"] = calendarEntries[0].plist

        default:
            plist["StartCalendarInterval"] = calendarEntries.map(\.plist)
        }
        plist["StartInterval"] = interval
        return plist
    }
}

extension Schedule.CalendarEntry {
    var plist: [String: Int] {
        [
            "Minute": minute,
            "Hour": hour,
            "Day": day,
            "Weekday": weekday,
            "Month": month,
        ].compactMapValues { $0 }
    }

    init(plist: [String: Any]) {
        minute = plist["Minute"] as? Int
        hour = plist["Hour"] as? Int
        day = plist["Day"] as? Int
        weekday = plist["Weekday"] as? Int
        month = plist["Month"] as? Int
    }

    /// 2月29日だけのような指定でも見つかるよう、閏年を挟む範囲まで日を進めて探す
    private static let searchDays = 366 * 8

    func nextRun(after date: Date, calendar: Calendar) -> Date? {
        let startDay = calendar.startOfDay(for: date)
        let hours = hour.map { [$0] } ?? Array(0..<24)
        let minutes = minute.map { [$0] } ?? Array(0..<60)
        for offset in 0..<Self.searchDays {
            guard
                let day = calendar.date(byAdding: .day, value: offset, to: startDay),
                matches(day: day, calendar: calendar)
            else {
                continue
            }
            for hour in hours {
                for minute in minutes {
                    guard
                        let run = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                        run > date
                    else {
                        continue
                    }
                    return run
                }
            }
        }
        return nil
    }

    /// `nextRun` を過去へ向けたもの。同じ時刻ちょうどは「その予定が来た」とみなして含める
    func previousRun(atOrBefore date: Date, calendar: Calendar) -> Date? {
        let startDay = calendar.startOfDay(for: date)
        let hours = (hour.map { [$0] } ?? Array(0..<24)).reversed()
        let minutes = (minute.map { [$0] } ?? Array(0..<60)).reversed()
        for offset in 0..<Self.searchDays {
            guard
                let day = calendar.date(byAdding: .day, value: -offset, to: startDay),
                matches(day: day, calendar: calendar)
            else {
                continue
            }
            for hour in hours {
                for minute in minutes {
                    guard
                        let run = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                        run <= date
                    else {
                        continue
                    }
                    return run
                }
            }
        }
        return nil
    }

    /**
     Day と Weekday の両方があるときは cron と同じくどちらかに合えば実行する（推測: launchd は cron 互換）。
     Calendar の weekday は 1 が日曜なので、launchd の 0〜7 を `% 7 + 1` で合わせる
     */
    private func matches(day date: Date, calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.day, .weekday, .month], from: date)
        guard month == nil || components.month == month else {
            return false
        }
        let dayChecks = [
            day.map { components.day == $0 },
            weekday.map { components.weekday == $0 % 7 + 1 },
        ].compactMap { $0 }
        return dayChecks.isEmpty || dayChecks.contains(true)
    }
}
