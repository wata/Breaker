import SwiftUI

extension ScheduleEditorView {
    /// 時刻指定の1行。曜日のボタンは時刻と同じ行に並べると最小幅に収まらないので、次の行に置く
    struct EntryRow: View {
        @Binding var row: ViewModel.Row
        let canRemove: Bool
        let remove: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.tight) {
                    Picker("Repeat", selection: $row.repetition) {
                        ForEach(ViewModel.Repetition.allCases, id: \.self) { repetition in
                            Text(repetition.title)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    if row.repetition == .monthly {
                        let (prefix, suffix) = ScheduleEditorView.dayFieldWords

                        if !prefix.isEmpty {
                            Text(prefix)
                        }

                        NumberField(title: "Day", value: $row.day)

                        if !suffix.isEmpty {
                            Text(suffix)
                        }
                    }

                    Spacer()

                    Picker("Hour", selection: $row.hourMode) {
                        ForEach(ViewModel.HourMode.allCases, id: \.self) { hourMode in
                            Text(hourMode.title)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    if row.hourMode != .everyHour {
                        NumberField(title: "Hour", value: $row.hour)
                    }

                    if row.hourMode == .range {
                        Text(verbatim: "–")

                        NumberField(title: "End Hour", value: $row.endHour)
                    }

                    Text(verbatim: ":")

                    NumberField(title: "Minute", value: $row.minute, digits: 2)

                    Button("Remove This Time", systemImage: "minus.circle", action: remove)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(!canRemove)
                }

                if row.repetition == .weekly {
                    HStack(spacing: Spacing.micro) {
                        ForEach(ViewModel.weekdayOrder, id: \.self) { weekday in
                            Toggle(Schedule.weekdayName(weekday), isOn: $row.weekdays[contains: weekday])
                                .toggleStyle(.button)
                        }
                    }
                }

                if let problem = row.problem {
                    ProblemText(problem: problem)
                }
            }
        }
    }

    /**
     日付の欄の前後に置く語。英語は「Day 1」、日本語は「1日」と、欄の前後どちらに語を置くかが言語で違うので、
     欄の位置に目印を差し込んだ訳を目印で前後に分ける
     */
    private static var dayFieldWords: (prefix: String, suffix: String) {
        let marker = "\u{FFFC}"
        let parts = String(localized: "Day \(marker)", comment: "Day-of-month field in the schedule editor. %@ marks where the number field goes")
            .components(separatedBy: marker)
        return (
            parts.first?.trimmingCharacters(in: .whitespaces) ?? "",
            parts.dropFirst().joined().trimmingCharacters(in: .whitespaces)
        )
    }

    struct IntervalRow: View {
        @Binding var value: Int
        @Binding var unit: ViewModel.IntervalUnit
        let problem: String?

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.tight) {
                    NumberField(title: "Interval", value: $value)

                    Picker("Unit", selection: $unit) {
                        ForEach(ViewModel.IntervalUnit.allCases, id: \.self) { unit in
                            Text(unit.title(for: value))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    Spacer()
                }

                if let problem {
                    ProblemText(problem: problem)
                }
            }
        }
    }

    /// 範囲外の値も入力できるようにし、保存の前に `problem` で知らせる
    struct NumberField: View {
        let title: LocalizedStringKey
        @Binding var value: Int
        /// 分は「9:05」と読めるよう2桁で出す
        var digits = 1

        var body: some View {
            TextField(title, value: $value, format: .number.grouping(.never).precision(.integerLength(digits...)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: Layout.numberFieldWidth)
        }
    }

    struct ProblemText: View {
        let problem: String

        var body: some View {
            Text(problem)
                .font(.Small.regular)
                .foregroundStyle(Color.Status.failure)
        }
    }
}

extension Set {
    /// 曜日のトグルを `Set` の要素の有無に結びつける
    fileprivate subscript(contains element: Element) -> Bool {
        get {
            contains(element)
        }
        set {
            if newValue {
                insert(element)
            } else {
                remove(element)
            }
        }
    }
}
