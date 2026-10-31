import Foundation

extension Schedule {
    /// 詳細ペインに出す起動条件。1行に1条件（「平日 9:00」「30分ごと」「ログイン時」など）
    var summaryLines: [String] {
        summaryLines(locale: .current)
    }

    func summaryLines(locale: Locale) -> [String] {
        var lines = Self.calendarLines(calendarEntries, locale: locale)
        if
            let interval,
            interval > 0
        {
            lines.append(Self.intervalText(seconds: interval, locale: locale))
        }
        if runAtLoad {
            lines.append(String(localized: "At login", language: locale))
        }
        if keepAlive {
            lines.append(String(localized: "Always running (KeepAlive)", language: locale))
        }
        if !watchPaths.isEmpty {
            lines.append(String(localized: "Watching files: \(watchPaths.joined(separator: ", "))", language: locale))
        }
        return lines.isEmpty ? [String(localized: "No launch triggers", language: locale)] : lines
    }

    /// 割り切れる最大の単位で「◯ごと」と表す（5400 秒は「90分ごと」）。英語は1のとき「Every hour」のように数を省くので、単位ごとに複数形の訳を持つ
    static func intervalText(seconds: Int, locale: Locale = .current) -> String {
        if seconds % 86400 == 0 {
            return String(localized: "Every \(seconds / 86400) days", language: locale)
        }
        if seconds % 3600 == 0 {
            return String(localized: "Every \(seconds / 3600) hours", language: locale)
        }
        if seconds % 60 == 0 {
            return String(localized: "Every \(seconds / 60) minutes", language: locale)
        }
        return String(localized: "Every \(seconds) seconds", language: locale)
    }

    /// launchd の Weekday（0 が日曜）の短い名前。スケジュール編集の曜日ボタンにも使う
    static func weekdayName(_ weekday: Int, locale: Locale = .current) -> String {
        switch weekday % 7 {
        case 0:
            String(localized: LocalizedStringResource("Sun", comment: "Short weekday name (Sunday)"), language: locale)

        case 1:
            String(localized: LocalizedStringResource("Mon", comment: "Short weekday name (Monday)"), language: locale)

        case 2:
            String(localized: LocalizedStringResource("Tue", comment: "Short weekday name (Tuesday)"), language: locale)

        case 3:
            String(localized: LocalizedStringResource("Wed", comment: "Short weekday name (Wednesday)"), language: locale)

        case 4:
            String(localized: LocalizedStringResource("Thu", comment: "Short weekday name (Thursday)"), language: locale)

        case 5:
            String(localized: LocalizedStringResource("Fri", comment: "Short weekday name (Friday)"), language: locale)

        default:
            String(localized: LocalizedStringResource("Sat", comment: "Short weekday name (Saturday)"), language: locale)
        }
    }

    /// 曜日1つだけの指定。英語は「Mondays」、日本語は「毎週月曜」
    private static func everyWeekdayName(_ weekday: Int, locale: Locale) -> String {
        switch weekday % 7 {
        case 0:
            String(localized: LocalizedStringResource("Sundays", comment: "Schedule that runs every Sunday"), language: locale)

        case 1:
            String(localized: LocalizedStringResource("Mondays", comment: "Schedule that runs every Monday"), language: locale)

        case 2:
            String(localized: LocalizedStringResource("Tuesdays", comment: "Schedule that runs every Tuesday"), language: locale)

        case 3:
            String(localized: LocalizedStringResource("Wednesdays", comment: "Schedule that runs every Wednesday"), language: locale)

        case 4:
            String(localized: LocalizedStringResource("Thursdays", comment: "Schedule that runs every Thursday"), language: locale)

        case 5:
            String(localized: LocalizedStringResource("Fridays", comment: "Schedule that runs every Friday"), language: locale)

        default:
            String(localized: LocalizedStringResource("Saturdays", comment: "Schedule that runs every Saturday"), language: locale)
        }
    }

    /**
     平日 9:00 は launchd では曜日ごとの5エントリになるので、曜日以外が同じエントリを1行にまとめる。
     曜日の指定がないエントリが1つでも混じれば、その時刻は毎日動く。
     スケジュール編集で時の範囲にした 7:00〜23:00 の毎時は時ごとのエントリになるので、時だけが1ずつ続く隣り合った行も1行にまとめる
     */
    private static func calendarLines(_ entries: [CalendarEntry], locale: Locale) -> [String] {
        let keys = entries.reduce(into: [CalendarEntry]()) { keys, entry in
            let key = entry.ignoringWeekday
            guard !keys.contains(key) else { return }
            keys.append(key)
        }
        let groups = keys.reduce(into: [(entry: CalendarEntry, weekdays: Set<Int>?, endHour: Int?)]()) { groups, key in
            let weekdays = entries.filter { $0.ignoringWeekday == key }.map(\.weekday)
            let weekdaySet = weekdays.contains(nil) ? nil : Set(weekdays.compactMap { $0.map { $0 % 7 } })
            guard
                let last = groups.last,
                let hour = key.hour,
                key.minute != nil,
                (last.endHour ?? last.entry.hour).map({ $0 + 1 }) == hour,
                last.entry.ignoringHour == key.ignoringHour,
                last.weekdays == weekdaySet
            else {
                groups.append((key, weekdaySet, nil))
                return
            }
            groups[groups.count - 1].endHour = hour
        }
        return groups.map { line($0.entry, weekdays: $0.weekdays, endHour: $0.endHour, locale: locale) }
    }

    /**
     日の部分と時刻の部分をつなぐ。英語は時刻なら「at」、「毎分」のような句ならカンマでつなぐので、語順ごとに訳を持つ。
     `endHour` があれば `entry.hour` からその時までの毎時
     */
    private static func line(_ entry: CalendarEntry, weekdays: Set<Int>?, endHour: Int?, locale: Locale) -> String {
        let weekdays = weekdays.flatMap { weekdayText($0, locale: locale) }
        let days = dayText(day: entry.day, weekdays: weekdays, locale: locale)
        let date: String? = switch (entry.month, entry.day, weekdays) {
        case (let month?, let day?, nil):
            String(
                localized: LocalizedStringResource("\(monthName(month, locale: locale)) \(day)", comment: "Month and day of a schedule, e.g. Jan 1"),
                language: locale
            )

        case (nil, let day?, nil):
            String(localized: "Monthly on day \(day)", language: locale)

        case (let month?, _, _):
            String(localized: "\(days ?? everyDay(locale: locale)) in \(monthName(month, locale: locale))", language: locale)

        case (nil, _, _):
            days
        }

        switch (entry.hour, entry.minute) {
        case (let hour?, let minute?):
            let time = clockText(hour: hour, minute: minute, locale: locale)
            guard let endHour else {
                return String(localized: "\(date ?? everyDay(locale: locale)) at \(time)", language: locale)
            }
            let endTime = clockText(hour: endHour, minute: minute, locale: locale)
            return String(localized: "\(date ?? everyDay(locale: locale)), every hour from \(time) to \(endTime)", language: locale)

        case (let hour?, nil):
            return String(localized: "\(date ?? everyDay(locale: locale)), every minute during hour \(hour)", language: locale)

        // 「毎時30分」「毎分」は毎日を付けなくても伝わる
        case (nil, let minute?):
            return if let date {
                String(localized: "\(date), every hour at minute \(minute)", language: locale)
            } else {
                String(localized: "Every hour at minute \(minute)", language: locale)
            }

        case (nil, nil):
            return if let date {
                String(localized: "\(date), every minute", language: locale)
            } else {
                String(localized: "Every minute", language: locale)
            }
        }
    }

    private static func everyDay(locale: Locale) -> String {
        String(localized: LocalizedStringResource("Every day", comment: "Schedule that runs daily"), language: locale)
    }

    /// launchd は Day と Weekday の両方があればどちらかに合えば動く（`Schedule.CalendarEntry.matches` と同じ解釈）
    private static func dayText(day: Int?, weekdays: String?, locale: Locale) -> String? {
        switch (day, weekdays) {
        case (let day?, let weekdays?):
            String(localized: "Day \(day) or \(weekdays)", language: locale)

        case (let day?, nil):
            String(localized: "Day \(day)", language: locale)

        case (nil, let weekdays?):
            weekdays

        case (nil, nil):
            nil
        }
    }

    /// 7曜日すべては曜日の指定がないのと同じなので nil
    private static func weekdayText(_ weekdays: Set<Int>, locale: Locale) -> String? {
        switch weekdays {
        case Set(1...5):
            return String(localized: LocalizedStringResource("Weekdays", comment: "Schedule that runs Monday through Friday"), language: locale)

        case [0, 6]:
            return String(localized: LocalizedStringResource("Weekends", comment: "Schedule that runs on Saturday and Sunday"), language: locale)

        case Set(0...6):
            return nil

        default:
            // 月曜始まりで並べる
            let sorted = weekdays.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }
            guard sorted.count > 1 else {
                return sorted.first.map { everyWeekdayName($0, locale: locale) }
            }
            let separator = String(
                localized: LocalizedStringResource(
                    "WeekdayListSeparator",
                    defaultValue: ", ",
                    comment: "Separator between short weekday names in a schedule, e.g. Mon, Wed, Fri"
                ),
                language: locale
            )
            return sorted.map { weekdayName($0, locale: locale) }.joined(separator: separator)
        }
    }

    /// 英語は「Jan」、日本語は「1月」
    private static func monthName(_ month: Int, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.shortMonthSymbols
        return symbols.indices.contains(month - 1) ? symbols[month - 1] : "\(month)"
    }

    /// 英語は「9:00 AM」、日本語は「9:00」。時と分だけを書式に渡すため、夏時間のない GMT の固定の日に載せる
    private static func clockText(hour: Int, minute: Int, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = .gmt
        guard let date = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)) else {
            return String(format: "%d:%02d", hour, minute)
        }
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: .gmt))
    }
}

extension Schedule.CalendarEntry {
    fileprivate var ignoringWeekday: Self {
        var entry = self
        entry.weekday = nil
        return entry
    }

    fileprivate var ignoringHour: Self {
        var entry = self
        entry.hour = nil
        return entry
    }
}
