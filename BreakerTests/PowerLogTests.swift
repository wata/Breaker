import Foundation
import Testing
@testable import Breaker

struct PowerLogTests {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private static func at(_ minutes: Double) -> Date {
        base.addingTimeInterval(minutes * 60)
    }

    // MARK: - 解析

    @Test func readsWakeToSleepAndShutdown() {
        let log = [
            pmsetLine(Self.at(0), "Wake", "Wake from Deep Idle [CDNVA] : due to lid"),
            pmsetLine(Self.at(30), "Sleep", "Entering Sleep state due to 'Clamshell Sleep'"),
            pmsetLine(Self.at(60), "Start", "powerd process is started"),
            pmsetLine(Self.at(90), "Shutdown", "Shutdown cause"),
        ].joined(separator: "\n")
        #expect(PowerLog.awakeIntervals(in: log, until: Self.at(120)) == [
            .init(start: Self.at(0), end: Self.at(30)),
            .init(start: Self.at(60), end: Self.at(90)),
        ])
    }

    /// DarkWake は起きていたに含めない。DarkWake から Wake に上がったら、その Wake から数える
    @Test func excludesDarkWake() {
        let log = [
            pmsetLine(Self.at(0), "Wake"),
            pmsetLine(Self.at(10), "Sleep"),
            pmsetLine(Self.at(20), "DarkWake", "DarkWake from Deep Idle [CDNP]"),
            pmsetLine(Self.at(21), "Sleep"),
            pmsetLine(Self.at(30), "DarkWake"),
            pmsetLine(Self.at(31), "Wake"),
            pmsetLine(Self.at(40), "Sleep"),
        ].joined(separator: "\n")
        #expect(PowerLog.awakeIntervals(in: log, until: Self.at(120)) == [
            .init(start: Self.at(0), end: Self.at(10)),
            .init(start: Self.at(31), end: Self.at(40)),
        ])
    }

    /// 閉じていない最後の起床はログを取った時刻まで。最初の Wake / Start より前の Sleep は区間にしない
    @Test func closesLastWakeAtEnd() {
        let log = [
            pmsetLine(Self.at(0), "Sleep"),
            pmsetLine(Self.at(10), "Wake"),
            pmsetLine(Self.at(20), "Wake"),
        ].joined(separator: "\n")
        #expect(PowerLog.awakeIntervals(in: log, until: Self.at(60)) == [.init(start: Self.at(10), end: Self.at(60))])
    }

    /// 起きているのに Start が来たら、記録されずに電源が切れていたので、その前の最後の行の時刻で閉じる
    @Test func closesAtLastLineBeforeUnexpectedStart() {
        let log = [
            pmsetLine(Self.at(0), "Start", "powerd process is started"),
            pmsetLine(Self.at(50), "Assertions", "PID 1(x) Released PreventUserIdleSystemSleep"),
            "Sleep/Wakes since boot at 2026-10-27 03:20:09 +0900 :0",
            "Time stamp                Domain              \tMessage",
            pmsetLine(Self.at(300), "Start", "powerd process is started"),
        ].joined(separator: "\n")
        #expect(PowerLog.awakeIntervals(in: log, until: Self.at(400)) == [
            .init(start: Self.at(0), end: Self.at(50)),
            .init(start: Self.at(300), end: Self.at(400)),
        ])
    }

    /// `Wake Requests` など名前が Wake で始まる別の種類、見出し、壊れた行は飛ばす
    @Test func skipsOtherAndBrokenLines() {
        let log = [
            "PM ASL data store: /var/log/powermanagement",
            "==========                ======              \t=======",
            pmsetLine(Self.at(0), "Wake Requests", "[process=dasd request=SleepService]"),
            pmsetLine(Self.at(1), "WakeDetails"),
            pmsetLine(Self.at(2), "Assertions"),
            "2026-13-45 99:99:99 +0900 Wake                \tbroken date",
            "2026-10-27 17:22:53 +0900 Wake",
            "   id=557  level=255 0x100=MAGICWAKE creat=2026/10/30, 12:29",
            "",
            pmsetLine(Self.at(10), "Wake"),
            pmsetLine(Self.at(20), "Kernel Client Acks", "Delays to Sleep notifications"),
            pmsetLine(Self.at(30), "Sleep"),
        ].joined(separator: "\n")
        #expect(PowerLog.awakeIntervals(in: log, until: Self.at(60)) == [.init(start: Self.at(10), end: Self.at(30))])
    }

    /// 時刻は行ごとの時差で読む（旅行先で取ったログも混ざりうる）
    @Test func readsTimeZoneOffset() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let log = [
            pmsetLine(Self.at(0), "Wake", timeZone: tokyo),
            pmsetLine(Self.at(30), "Sleep", timeZone: newYork),
        ].joined(separator: "\n")
        #expect(PowerLog.awakeIntervals(in: log, until: Self.at(60)) == [.init(start: Self.at(0), end: Self.at(30))])
    }

    @Test func requiresAwakeThroughoutDuration() {
        let intervals = [PowerLog.Interval(start: Self.at(0), end: Self.at(30))]
        #expect(PowerLog.isAwake(at: Self.at(0), for: 30 * 60, in: intervals))
        #expect(PowerLog.isAwake(at: Self.at(10), for: 10 * 60, in: intervals))
        #expect(!PowerLog.isAwake(at: Self.at(25), for: 10 * 60, in: intervals))
        #expect(!PowerLog.isAwake(at: Self.at(-1), for: 10 * 60, in: intervals))
        #expect(!PowerLog.isAwake(at: Self.at(10), for: 10 * 60, in: []))
    }

    // MARK: - 覚えておく

    @Test func answersFromLoadedLogWithoutReloading() async {
        let shell = StubShell(output: ShellOutput(status: 0, stdout: pmsetLine(Self.at(0), "Wake"), stderr: ""))
        let history = AwakeHistory(shell: shell)
        await history.load(now: Self.at(60))
        #expect(await history.wasAwake(at: Self.at(10), for: 10 * 60, now: Self.at(61)))
        #expect(await !history.wasAwake(at: Self.at(-10), for: 5 * 60, now: Self.at(61)))
        // 取った時刻より後のことは分からないので false。間隔の下限の内なので取り直しもしない
        #expect(await !history.wasAwake(at: Self.at(55), for: 10 * 60, now: Self.at(70)))
        #expect(shell.calls == [.init(executable: "/usr/bin/pmset", arguments: ["-g", "log"])])
    }

    /// 取り直しは待たずに false を返し、裏で取る
    @Test func reloadsInBackgroundAfterMinimumInterval() async throws {
        let shell = StubShell(output: ShellOutput(status: 0, stdout: pmsetLine(Self.at(0), "Wake"), stderr: ""))
        let history = AwakeHistory(shell: shell)
        await history.load(now: Self.at(60))
        #expect(await !history.wasAwake(at: Self.at(80), for: 10 * 60, now: Self.at(100)))
        for _ in 0..<200 where shell.calls.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(shell.calls.count == 2)
    }

    /// `pmset` が失敗したら履歴は無い扱い（起きていたとは言わない）
    @Test func treatsFailureAsNoHistory() async {
        let history = AwakeHistory(shell: StubShell(output: ShellOutput(status: 1, stdout: pmsetLine(Self.at(0), "Wake"), stderr: "error")))
        await history.load(now: Self.at(60))
        #expect(await !history.wasAwake(at: Self.at(10), for: 10 * 60, now: Self.at(61)))
    }
}
