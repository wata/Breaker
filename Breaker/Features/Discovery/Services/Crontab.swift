import Foundation

/**
 `crontab -l` の解釈。macOS の cron（FreeBSD 由来の Vixie cron）の crontab(5) に合わせる。
 コメント・空行・環境変数の行は項目にせず、それ以外の行は解釈できなくても1行1項目にする（黙って消すと、壊れた行に気づけない）
 */
enum Crontab {
    struct Entry: Hashable, Sendable {
        /// 前後の空白を除いた行
        let line: String
        /// 解釈できない行は nil
        let job: Job?
    }

    struct Job: Hashable, Sendable {
        /// 時刻の指定の部分（`0 3 * * *`・`@daily`）
        let expression: String
        let timing: Timing
        /// 時刻の指定の後ろ全部。`%` 以降（cron が標準入力に渡す部分）も含める
        let command: String
    }

    enum Timing: Hashable, Sendable {
        /// cron の起動時（`@reboot`）
        case reboot
        case fields(Fields)
    }

    /**
     5つのフィールドを数の集合に開いたもの。曜日の 7 は 0（日曜）にそろえる。
     日と曜日がどちらも `*` で始まらないときだけ「どちらかに一致」になる（`*` で始まる側があれば両方に一致）ので、`*` で始まったかも持つ
     */
    struct Fields: Hashable, Sendable {
        let minutes: Set<Int>
        let hours: Set<Int>
        let days: Set<Int>
        let months: Set<Int>
        let weekdays: Set<Int>
        let isDayStar: Bool
        let isWeekdayStar: Bool
    }

    /// `@hourly` などの別名を5つのフィールドに直したもの（crontab(5) の表のとおり）
    private static let macros = [
        "@yearly": "0 0 1 1 *",
        "@annually": "0 0 1 1 *",
        "@monthly": "0 0 1 * *",
        "@weekly": "0 0 * * 0",
        "@daily": "0 0 * * *",
        "@midnight": "0 0 * * *",
        "@hourly": "0 * * * *",
    ]

    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    static func parse(_ text: String) -> [Entry] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard
                !line.isEmpty,
                !line.hasPrefix("#"),
                !isEnvironmentAssignment(line)
            else {
                return nil
            }
            return Entry(line: line, job: job(line))
        }
    }

    /// `NAME = value`。5つのフィールドの行は数字か `*` で始まるので、名前で始まる行と取り違えない
    private static func isEnvironmentAssignment(_ line: String) -> Bool {
        line.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*\s*=.*/) != nil
    }

    private static func job(_ line: String) -> Job? {
        if line.hasPrefix("@") {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let name = parts[0].lowercased()
            guard
                parts.count == 2,
                let command = nonEmptyCommand(parts[1])
            else {
                return nil
            }
            if name == "@reboot" {
                return Job(expression: String(parts[0]), timing: .reboot, command: command)
            }
            guard
                let expanded = macros[name],
                let fields = fields(expanded.split(separator: " ").map(String.init))
            else {
                return nil
            }
            return Job(expression: String(parts[0]), timing: .fields(fields), command: command)
        }
        let parts = line.split(maxSplits: 5, whereSeparator: \.isWhitespace)
        guard
            parts.count == 6,
            let command = nonEmptyCommand(parts[5]),
            let fields = fields(parts.prefix(5).map(String.init))
        else {
            return nil
        }
        return Job(expression: parts.prefix(5).joined(separator: " "), timing: .fields(fields), command: command)
    }

    private static func nonEmptyCommand(_ text: Substring) -> String? {
        let command = text.trimmingCharacters(in: .whitespaces)
        return command.isEmpty ? nil : command
    }

    private static func fields(_ texts: [String]) -> Fields? {
        guard
            texts.count == 5,
            let minutes = values(of: texts[0], in: 0...59),
            let hours = values(of: texts[1], in: 0...23),
            let days = values(of: texts[2], in: 1...31),
            let months = values(of: texts[3], in: 1...12, names: monthNames, firstNameValue: 1),
            let weekdays = values(of: texts[4], in: 0...7, names: weekdayNames, firstNameValue: 0)
        else {
            return nil
        }
        return Fields(
            minutes: minutes,
            hours: hours,
            days: days,
            months: months,
            weekdays: Set(weekdays.map { $0 % 7 }),
            isDayStar: texts[2].hasPrefix("*"),
            isWeekdayStar: texts[4].hasPrefix("*")
        )
    }

    /**
     `,` で区切った要素の和集合。要素は `*`・`n`・`n-m` に `/step` を付けられる（`n/step` は macOS の cron でも誤りになるので受け付けない）。
     月と曜日は3文字の英語名（大文字小文字を問わない）を数の代わりに書ける
     */
    private static func values(of field: String, in range: ClosedRange<Int>, names: [String] = [], firstNameValue: Int = 0) -> Set<Int>? {
        var result = Set<Int>()
        for element in field.split(separator: ",", omittingEmptySubsequences: false) {
            let stepParts = element.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let step: Int
            if stepParts.count == 2 {
                guard
                    let value = Int(stepParts[1]),
                    value > 0
                else {
                    return nil
                }
                step = value
            } else {
                step = 1
            }
            let bounds: ClosedRange<Int>
            if stepParts[0] == "*" {
                bounds = range
            } else {
                let rangeParts = stepParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                guard
                    let low = value(of: rangeParts[0], names: names, firstNameValue: firstNameValue),
                    range.contains(low)
                else {
                    return nil
                }
                guard rangeParts.count == 2 else {
                    guard stepParts.count == 1 else {
                        return nil
                    }
                    result.insert(low)
                    continue
                }
                guard
                    let high = value(of: rangeParts[1], names: names, firstNameValue: firstNameValue),
                    range.contains(high),
                    low <= high
                else {
                    return nil
                }
                bounds = low...high
            }
            result.formUnion(stride(from: bounds.lowerBound, through: bounds.upperBound, by: step))
        }
        return result
    }

    private static func value(of text: Substring, names: [String], firstNameValue: Int) -> Int? {
        if let number = Int(text) {
            return number
        }
        return names.firstIndex(of: text.lowercased()).map { $0 + firstNameValue }
    }
}

extension Crontab.Fields {
    /**
     `Schedule` の CalendarEntry は各キーが1つの値か「毎回」なので、各フィールドの値の組み合わせごとに1エントリにする。
     全部の値を取るフィールドは「毎回」にまとめる。組み合わせがこれより多いと次回の計算と要約が重くなるので変換しない
     */
    static let maxCalendarEntries = 1000

    /**
     既存の次回の計算と要約を使うための変換。表せないときは nil。
     CalendarEntry は日と曜日の両方があると「どちらかに一致」になるので、cron が「両方に一致」とする（日か曜日が `*` で始まる）のに
     両方が絞られている（日を `*` から間隔で、曜日を `mon` で書いたときなど）ときは表せない
     */
    var schedule: Schedule? {
        let isEveryDay = days.count == 31
        let isEveryWeekday = weekdays.count == 7
        let dayValues: [Int?]
        let weekdayValues: [Int?]
        if isDayStar || isWeekdayStar {
            guard isEveryDay || isEveryWeekday else {
                return nil
            }
            dayValues = isEveryDay ? [nil] : days.sorted()
            weekdayValues = isEveryWeekday ? [nil] : weekdays.sorted()
        } else if isEveryDay || isEveryWeekday {
            // どちらかが全部なら、どちらかに一致は毎日
            dayValues = [nil]
            weekdayValues = [nil]
        } else {
            dayValues = days.sorted()
            weekdayValues = weekdays.sorted()
        }
        let minuteValues: [Int?] = minutes.count == 60 ? [nil] : minutes.sorted()
        let hourValues: [Int?] = hours.count == 24 ? [nil] : hours.sorted()
        let monthValues: [Int?] = months.count == 12 ? [nil] : months.sorted()
        let count = minuteValues.count * hourValues.count * dayValues.count * monthValues.count * weekdayValues.count
        guard count <= Self.maxCalendarEntries else {
            return nil
        }
        var entries: [Schedule.CalendarEntry] = []
        for month in monthValues {
            for day in dayValues {
                for weekday in weekdayValues {
                    for hour in hourValues {
                        for minute in minuteValues {
                            entries.append(.init(minute: minute, hour: hour, day: day, weekday: weekday, month: month))
                        }
                    }
                }
            }
        }
        return Schedule(calendarEntries: entries)
    }
}
