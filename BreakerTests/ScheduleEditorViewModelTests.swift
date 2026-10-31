import Foundation
import Testing
@testable import Breaker

@MainActor
struct ScheduleEditorViewModelTests {
    typealias Entry = Schedule.CalendarEntry
    typealias ViewModel = ScheduleEditorView.ViewModel

    private static let weekdays = Schedule(calendarEntries: (1...5).map { Entry(minute: 0, hour: 9, weekday: $0) })

    @Test func weekdayEntriesBecomeOneRowAndExpandOnSave() {
        let viewModel = ViewModel(schedule: Self.weekdays)
        #expect(viewModel.mode == .calendar)
        #expect(viewModel.rows.count == 1)
        #expect(viewModel.rows[0].repetition == .weekly)
        #expect(viewModel.rows[0].weekdays == Set(1...5))
        #expect(viewModel.schedule == Self.weekdays)
        #expect(viewModel.lossNotes.isEmpty)
    }

    @Test(arguments: [
        Schedule(calendarEntries: [Entry(minute: 0, hour: 11, day: 1)]),
        Schedule(calendarEntries: [Entry(minute: 0, hour: 8)]),
        Schedule(interval: 1800),
        Schedule(interval: 7200),
        Schedule(runAtLoad: true, keepAlive: true),
    ])
    func unchangedEditorReproducesSchedule(schedule: Schedule) {
        let viewModel = ViewModel(schedule: schedule)
        #expect(viewModel.schedule == schedule)
        #expect(viewModel.lossNotes.isEmpty)
    }

    @Test func intervalIsShownInLargestUnit() {
        let viewModel = ViewModel(schedule: Schedule(interval: 7200))
        #expect(viewModel.mode == .interval)
        #expect(viewModel.intervalValue == 2)
        #expect(viewModel.intervalUnit == .hours)
        #expect(ViewModel(schedule: Schedule(interval: 1800)).intervalUnit == .minutes)
    }

    /// 単位の語は隣の数に合わせて単数・複数を変える（「1 hours」にしない）
    @Test(arguments: [
        (ViewModel.IntervalUnit.minutes, 1, "minute"),
        (.minutes, 30, "minutes"),
        (.hours, 1, "hour"),
        (.hours, 2, "hours"),
    ])
    func intervalUnitTitleFollowsValue(unit: ViewModel.IntervalUnit, value: Int, title: String) {
        #expect(unit.title(for: value) == title)
    }

    /// 7 で書かれた日曜は 0 にそろえ、7曜日すべては毎日として1エントリで書く
    @Test func allWeekdaysCollapseToDaily() {
        let viewModel = ViewModel(schedule: Schedule(calendarEntries: (1...7).map { Entry(minute: 30, hour: 6, weekday: $0) }))
        #expect(viewModel.rows.map(\.repetition) == [.daily])
        #expect(viewModel.schedule?.calendarEntries == [Entry(minute: 30, hour: 6)])
    }

    @Test func entryWithoutWeekdayMakesTheTimeDaily() {
        let viewModel = ViewModel(schedule: Schedule(calendarEntries: [Entry(minute: 0, hour: 9, weekday: 1), Entry(minute: 0, hour: 9)]))
        #expect(viewModel.rows.map(\.repetition) == [.daily])
    }

    @Test func differentTimesStaySeparateRows() {
        let entries = [Entry(minute: 0, hour: 9, weekday: 1), Entry(minute: 0, hour: 18, weekday: 1), Entry(minute: 0, hour: 9, weekday: 3)]
        let viewModel = ViewModel(schedule: Schedule(calendarEntries: entries))
        #expect(viewModel.rows.map(\.weekdays) == [[1, 3], [1]])
        #expect(viewModel.rows.map(\.hour) == [9, 18])
    }

    @Test func unsupportedEntriesAreReportedAsLost() {
        let viewModel = ViewModel(schedule: Schedule(calendarEntries: [Entry(minute: 0, hour: 8), Entry(minute: 15, month: 2), Entry(minute: 30)]))
        #expect(viewModel.rows.count == 1)
        #expect(viewModel.lossNotes.count == 1)
        #expect(viewModel.schedule?.calendarEntries == [Entry(minute: 0, hour: 8)])
    }

    @Test func bothCalendarAndIntervalWarnsAndKeepsCalendar() {
        let viewModel = ViewModel(schedule: Schedule(calendarEntries: [Entry(minute: 0, hour: 8)], interval: 600))
        #expect(viewModel.mode == .calendar)
        #expect(viewModel.lossNotes.count == 1)
        #expect(viewModel.schedule?.interval == nil)
    }

    @Test func switchingModesReplacesTimers() {
        let viewModel = ViewModel(schedule: Self.weekdays)
        viewModel.mode = .interval
        viewModel.intervalValue = 30
        viewModel.intervalUnit = .minutes
        #expect(viewModel.schedule == Schedule(interval: 1800))

        viewModel.mode = .none
        #expect(viewModel.schedule == Schedule())
    }

    /// RunAtLoad・KeepAlive・WatchPaths は編集できないので、時刻を足してもそのまま残る
    @Test func addingCalendarToKeepAliveJobKeepsOtherConditions() {
        let viewModel = ViewModel(schedule: Schedule(runAtLoad: true, keepAlive: true, watchPaths: ["/tmp"]))
        #expect(viewModel.mode == .none)
        viewModel.mode = .calendar
        viewModel.rows[0].repetition = .monthly
        viewModel.rows[0].day = 15
        viewModel.rows[0].hour = 7
        viewModel.rows[0].minute = 45
        #expect(viewModel.schedule == Schedule(
            calendarEntries: [Entry(minute: 45, hour: 7, day: 15)],
            runAtLoad: true,
            keepAlive: true,
            watchPaths: ["/tmp"]
        ))
    }

    @Test func addAndRemoveRows() {
        let viewModel = ViewModel(schedule: Self.weekdays)
        viewModel.addRow()
        #expect(viewModel.rows.count == 2)
        #expect(viewModel.schedule?.calendarEntries.count == 6)

        viewModel.removeRow(viewModel.rows[0].id)
        #expect(viewModel.rows.count == 1)
        #expect(viewModel.rows[0].repetition == .daily)

        viewModel.removeRow(viewModel.rows[0].id)
        #expect(viewModel.calendarProblem != nil)
        #expect(viewModel.schedule == nil)
    }

    @Test(arguments: [("hour", 24), ("hour", -1), ("minute", 60), ("minute", -1), ("day", 0), ("day", 32)])
    func outOfRangeValuesAreInvalid(field: String, value: Int) {
        let viewModel = ViewModel(schedule: Schedule(calendarEntries: [Entry(minute: 0, hour: 11, day: 1)]))
        switch field {
        case "hour":
            viewModel.rows[0].hour = value

        case "minute":
            viewModel.rows[0].minute = value

        default:
            viewModel.rows[0].day = value
        }
        #expect(viewModel.rows[0].problem != nil)
        #expect(viewModel.schedule == nil)
    }

    @Test func boundaryValuesAreValid() {
        let viewModel = ViewModel(schedule: Schedule(calendarEntries: [Entry(minute: 0, hour: 11, day: 1)]))
        viewModel.rows[0].hour = 23
        viewModel.rows[0].minute = 59
        viewModel.rows[0].day = 31
        #expect(viewModel.schedule?.calendarEntries == [Entry(minute: 59, hour: 23, day: 31)])
        viewModel.rows[0].hour = 0
        viewModel.rows[0].minute = 0
        viewModel.rows[0].day = 1
        #expect(viewModel.schedule != nil)
    }

    /// 日の値は「毎月」を選んだときだけ確かめる
    @Test func dayIsIgnoredUnlessMonthly() {
        let viewModel = ViewModel(schedule: Schedule(calendarEntries: [Entry(minute: 0, hour: 8)]))
        viewModel.rows[0].day = 0
        #expect(viewModel.schedule != nil)
    }

    @Test func weeklyNeedsAtLeastOneWeekday() {
        let viewModel = ViewModel(schedule: Self.weekdays)
        viewModel.rows[0].weekdays = []
        #expect(viewModel.schedule == nil)
        viewModel.rows[0].weekdays = [0, 6]
        #expect(viewModel.schedule?.calendarEntries.map(\.weekday) == [0, 6])
    }

    @Test(arguments: [0, -5])
    func nonPositiveIntervalIsInvalid(value: Int) {
        let viewModel = ViewModel(schedule: Schedule(interval: 1800))
        viewModel.intervalValue = value
        #expect(viewModel.intervalProblem != nil)
        #expect(viewModel.schedule == nil)
    }
}
