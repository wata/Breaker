import Foundation

extension ScheduleEditorView {
    /**
     StartCalendarInterval / StartInterval だけを編集する。RunAtLoad・KeepAlive・WatchPaths は元の値のまま
     `schedule` に載せ、プレビューの文言に含める（plist の書き換えでも触れない）
     */
    @MainActor
    @Observable
    final class ViewModel {
        enum Mode: CaseIterable {
            case none
            case calendar
            case interval

            var title: String {
                switch self {
                case .none:
                    String(localized: "None", comment: "Shown when there is nothing to show, e.g. no schedule trigger or no log output")

                case .calendar:
                    String(localized: "Specific Times", comment: "Schedule editor mode that runs at set times")

                case .interval:
                    String(localized: "Interval", comment: "Schedule editor mode that runs at a fixed interval")
                }
            }
        }

        enum Repetition: CaseIterable {
            case daily
            case weekly
            case monthly

            var title: String {
                switch self {
                case .daily:
                    String(localized: "Daily", comment: "Repeat option in the schedule editor")

                case .weekly:
                    String(localized: "Weekly", comment: "Repeat option in the schedule editor that runs on chosen days of the week")

                case .monthly:
                    String(localized: "Monthly", comment: "Repeat option in the schedule editor")
                }
            }
        }

        enum IntervalUnit: Int, CaseIterable {
            case minutes = 60
            case hours = 3600

            /**
             数は隣の入力欄に出すので、単位の語だけを返す。英語は数に合わせて単数・複数を変える。
             数を含まない文言は xcstrings の plural にできない（ビルドエラーになる）ので、Apple の案内どおり1とそれ以外で別の文言にする
             */
            func title(for value: Int) -> String {
                switch (self, value == 1) {
                case (.minutes, true):
                    String(localized: "minute", comment: "Unit after the interval number field in the schedule editor when the number is 1")

                case (.minutes, false):
                    String(localized: "minutes", comment: "Unit after the interval number field in the schedule editor, e.g. 30 minutes")

                case (.hours, true):
                    String(localized: "hour", comment: "Unit after the interval number field in the schedule editor when the number is 1")

                case (.hours, false):
                    String(localized: "hours", comment: "Unit after the interval number field in the schedule editor, e.g. 2 hours")
                }
            }
        }

        /**
         画面の1行。平日 9:00 は launchd では曜日ごとの5エントリだが、1行で月〜金を選んだ形で見せ、保存時に展開する。
         繰り返しを切り替えても曜日や日付の選択は残し、戻したときに失われないようにする
         */
        struct Row: Identifiable, Hashable {
            let id = UUID()
            var repetition = Repetition.daily
            /// launchd の表記（0 が日曜）。7 は読み込み時に 0 にそろえる
            var weekdays = Set(1...5)
            var day = 1
            var hour = 9
            var minute = 0

            var entries: [Schedule.CalendarEntry] {
                switch repetition {
                case .daily:
                    [Schedule.CalendarEntry(minute: minute, hour: hour)]

                case .weekly:
                    weekdays.sorted().map { Schedule.CalendarEntry(minute: minute, hour: hour, weekday: $0) }

                case .monthly:
                    [Schedule.CalendarEntry(minute: minute, hour: hour, day: day)]
                }
            }

            var problem: String? {
                [
                    (0...23).contains(hour) ? nil : String(localized: "Enter an hour from 0 to 23."),
                    (0...59).contains(minute) ? nil : String(localized: "Enter a minute from 0 to 59."),
                    repetition != .monthly || (1...31).contains(day) ? nil : String(localized: "Enter a day from 1 to 31."),
                    repetition != .weekly || !weekdays.isEmpty ? nil : String(localized: "Choose at least one day of the week."),
                ]
                .compactMap { $0 }
                .first
            }
        }

        /// 曜日の切り替えボタンは月曜始まりで並べる
        static let weekdayOrder = [1, 2, 3, 4, 5, 6, 0]

        var mode: Mode
        var rows: [Row]
        var intervalValue: Int
        var intervalUnit: IntervalUnit
        /// この画面で表せず、保存すると消える指定があるときの説明
        let lossNotes: [String]

        @ObservationIgnored
        private let original: Schedule

        init(schedule: Schedule) {
            original = schedule
            let (rows, isLossy) = Self.rows(from: schedule.calendarEntries)
            self.rows = rows.isEmpty ? [Row()] : rows

            let interval = schedule.interval ?? IntervalUnit.minutes.rawValue * 30
            let unit = interval % IntervalUnit.hours.rawValue == 0 ? IntervalUnit.hours : .minutes
            intervalUnit = unit
            intervalValue = max(interval / unit.rawValue, 1)

            mode = switch (schedule.calendarEntries.isEmpty, schedule.interval) {
            case (false, _):
                .calendar

            case (true, _?):
                .interval

            case (true, nil):
                .none
            }

            lossNotes = [
                isLossy
                    ? String(localized: "This editor can't show months or “every hour” and “every minute” times, so saving removes them.")
                    : nil,
                !schedule.calendarEntries.isEmpty && schedule.interval != nil
                    ? String(localized: "This job has both specific times and an interval. Saving keeps only the one you choose.")
                    : nil,
                schedule.interval.flatMap {
                    $0 % IntervalUnit.minutes.rawValue == 0 ? nil : String(localized: "The \($0)-second interval will be rounded to whole minutes when saved.")
                },
            ].compactMap { $0 }
        }

        var intervalProblem: String? {
            intervalValue > 0 ? nil : String(localized: "Enter an interval of 1 or more.")
        }

        var calendarProblem: String? {
            rows.isEmpty ? String(localized: "Add at least one time.") : nil
        }

        /// 入力に誤りがあれば nil。保存ボタンの可否とプレビューに使う
        var schedule: Schedule? {
            var schedule = original
            switch mode {
            case .none:
                schedule.calendarEntries = []
                schedule.interval = nil

            case .calendar:
                guard
                    calendarProblem == nil,
                    rows.allSatisfy({ $0.problem == nil })
                else {
                    return nil
                }
                schedule.calendarEntries = rows.flatMap(\.entries)
                schedule.interval = nil

            case .interval:
                guard intervalProblem == nil else {
                    return nil
                }
                schedule.calendarEntries = []
                schedule.interval = intervalValue * intervalUnit.rawValue
            }
            return schedule
        }

        func addRow() {
            rows.append(Row())
        }

        func removeRow(_ id: Row.ID) {
            rows.removeAll { $0.id == id }
        }

        /**
         曜日以外が同じエントリを1行にまとめる（`Schedule.summaryLines` と同じ考え方）。
         月・毎時・毎分の指定と、Day と Weekday の併用は1行で表せないので読み飛ばし、`isLossy` で知らせる
         */
        static func rows(from entries: [Schedule.CalendarEntry]) -> (rows: [Row], isLossy: Bool) {
            var rows = [Row]()
            var isLossy = false
            for entry in entries {
                guard
                    entry.month == nil,
                    let hour = entry.hour,
                    let minute = entry.minute,
                    entry.day == nil || entry.weekday == nil
                else {
                    isLossy = true
                    continue
                }
                if let day = entry.day {
                    rows.append(Row(repetition: .monthly, day: day, hour: hour, minute: minute))
                    continue
                }
                let index = rows.firstIndex { $0.repetition != .monthly && $0.hour == hour && $0.minute == minute }
                switch (index, entry.weekday) {
                case (let index?, let weekday?):
                    if rows[index].repetition == .weekly {
                        rows[index].weekdays.insert(weekday % 7)
                    }

                case (let index?, nil):
                    // 曜日の指定がないエントリが混じれば、その時刻は毎日動く
                    rows[index].repetition = .daily

                case (nil, let weekday?):
                    rows.append(Row(repetition: .weekly, weekdays: [weekday % 7], hour: hour, minute: minute))

                case (nil, nil):
                    rows.append(Row(repetition: .daily, hour: hour, minute: minute))
                }
            }
            for index in rows.indices where rows[index].repetition == .weekly && rows[index].weekdays.count == 7 {
                rows[index].repetition = .daily
            }
            return (rows, isLossy)
        }
    }
}
