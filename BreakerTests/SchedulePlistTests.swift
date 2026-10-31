import Foundation
import Testing
@testable import Breaker

/// `Schedule.applyingTimers(to:)` と `Schedule(plist:)` の往復。この Mac にある書き方をそのまま並べる
struct SchedulePlistTests {
    typealias Entry = Schedule.CalendarEntry

    static let patterns: [Schedule] = [
        Schedule(calendarEntries: (1...5).map { Entry(minute: 0, hour: 9, weekday: $0) }),
        Schedule(calendarEntries: [Entry(minute: 0, hour: 11, day: 1)]),
        Schedule(calendarEntries: [Entry(minute: 0, hour: 8)]),
        Schedule(interval: 1800),
        Schedule(calendarEntries: [Entry(minute: 15, hour: 3, month: 2)]),
    ]

    @Test(arguments: patterns)
    func roundTripsThroughSerializedPlist(schedule: Schedule) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: schedule.applyingTimers(to: [:]), format: .xml, options: 0)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(Schedule(plist: plist) == schedule)
    }

    @Test func singleEntryIsWrittenAsDictionary() throws {
        let plist = Schedule(calendarEntries: [Entry(minute: 0, hour: 8)]).applyingTimers(to: [:])
        let entry = try #require(plist["StartCalendarInterval"] as? [String: Int])
        #expect(entry == ["Hour": 8, "Minute": 0])
    }

    @Test func multipleEntriesAreWrittenAsArray() throws {
        let plist = Self.patterns[0].applyingTimers(to: [:])
        let entries = try #require(plist["StartCalendarInterval"] as? [[String: Int]])
        #expect(entries.map { $0["Weekday"] } == [1, 2, 3, 4, 5])
    }

    /// 使わなくなった方のキーは消し、RunAtLoad・KeepAlive などには触れない
    @Test func replacesOnlyTimerKeys() {
        let original: [String: Any] = [
            "Label": "com.example.job",
            "StartCalendarInterval": ["Hour": 9, "Minute": 0],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "WatchPaths": ["/tmp/watch"],
        ]

        let plist = Schedule(interval: 600, runAtLoad: false).applyingTimers(to: original)

        #expect(plist["StartCalendarInterval"] == nil)
        #expect(plist["StartInterval"] as? Int == 600)
        #expect(plist["Label"] as? String == "com.example.job")
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
        #expect(plist["WatchPaths"] as? [String] == ["/tmp/watch"])
    }

    @Test func emptyScheduleRemovesBothTimerKeys() {
        let plist = Schedule().applyingTimers(to: ["StartCalendarInterval": ["Hour": 9], "StartInterval": 60, "Label": "x"])
        #expect(Array(plist.keys) == ["Label"])
    }
}
