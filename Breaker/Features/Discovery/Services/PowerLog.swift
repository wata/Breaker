import Foundation

/**
 `pmset -g log` から、Mac が起きていた区間を取り出す。行は古い順に並び、
 `2026-10-27 17:22:53 +0900 Wake                \tWake from Deep Idle ...` のように日時・種類（空白で桁をそろえ、タブで区切る）・内容が続く
 */
enum PowerLog {
    struct Interval: Hashable, Sendable {
        let start: Date
        let end: Date
    }

    /// `2026-10-27 17:22:53 +0900` の長さ。種類はこの後の空白1つの次から始まる
    private static let timestampLength = 25

    /**
     Wake / Start から次の Sleep / Shutdown / DarkWake までを起きていた区間とする。
     DarkWake（画面が消えたままの短い起床）は、cron が予定を走らせられる状態とは言い切れないので起きていたに含めず、眠っている扱いにする。
     起きているのに Start が来たら、記録されずに電源が切れていたので、その前の最後の行の時刻で区間を閉じる。
     閉じていない最後の区間は `end`（ログを取った時刻）まで続いたとみなす。最初の Wake / Start より前は分からないので区間にしない
     */
    static func awakeIntervals(in text: String, until end: Date) -> [Interval] {
        var intervals: [Interval] = []
        var awakeStart: Date?
        var lastTimestamp: Substring?
        for line in text.split(separator: "\n") {
            guard
                let tab = line.firstIndex(of: "\t"),
                let timestamp = timestamp(in: line[..<tab])
            else {
                continue
            }
            defer { lastTimestamp = timestamp }
            let kind = line[line.index(timestamp.endIndex, offsetBy: 1)..<tab].trimmingCharacters(in: .whitespaces)
            switch kind {
            case "Start":
                if
                    let start = awakeStart,
                    let lastSeen = lastTimestamp.flatMap(date(from:)),
                    start < lastSeen
                {
                    intervals.append(Interval(start: start, end: lastSeen))
                }
                awakeStart = date(from: timestamp)

            case "Wake":
                guard awakeStart == nil else { continue }
                awakeStart = date(from: timestamp)

            case "Sleep", "Shutdown", "DarkWake":
                guard let start = awakeStart else { continue }
                awakeStart = nil
                guard
                    let sleep = date(from: timestamp),
                    start < sleep
                else {
                    continue
                }
                intervals.append(Interval(start: start, end: sleep))

            default:
                continue
            }
        }
        if
            let start = awakeStart,
            start < end
        {
            intervals.append(Interval(start: start, end: end))
        }
        return intervals
    }

    /// `date` に起きていて、そこから `duration` のあいだ眠らなかったか
    static func isAwake(at date: Date, for duration: TimeInterval, in intervals: [Interval]) -> Bool {
        intervals.contains { $0.start <= date && date.addingTimeInterval(duration) <= $0.end }
    }

    /// 行頭が日時で、その後に空白と種類が続くときだけ日時の部分を返す（見出しや続きの行を飛ばす）
    private static func timestamp(in head: Substring) -> Substring? {
        guard
            head.utf8.count > timestampLength + 1,
            head.utf8.first.map({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) == true
        else {
            return nil
        }
        return head.prefix(timestampLength)
    }

    /// 行ごとに書式を解釈すると重いので、桁の決まった `yyyy-MM-dd HH:mm:ss ±hhmm` を数字に分けて組み立てる
    private static func date(from timestamp: Substring) -> Date? {
        // 時差は `-0400` のように `-` を含むので、日時と分けてから区切る
        let zone = timestamp.suffix(5)
        let numbers = timestamp.dropLast(6).split { $0 == "-" || $0 == ":" || $0 == " " }.compactMap { Int($0) }
        guard
            numbers.count == 6,
            let sign = zone.first,
            sign == "+" || sign == "-",
            let offset = Int(zone.dropFirst()),
            let timeZone = TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (offset / 100 * 3600 + offset % 100 * 60))
        else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4], second: numbers[5])
        // Calendar は 13 月なども繰り上げて日付にしてしまうので、壊れた行は先に弾く
        guard components.isValidDate(in: calendar) else {
            return nil
        }
        return calendar.date(from: components)
    }
}
