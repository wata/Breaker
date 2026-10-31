import Testing
@testable import Breaker

struct ItemStatusTests {
    @Test(arguments: [
        (ItemStatus.ok, false),
        (.running, false),
        (.inactive(reason: "Disabled", note: "launchctl disable"), false),
        (.failed(reason: "Exit code 1"), true),
        (.warning(reason: "Running from outside /Applications"), true),
        // 閲覧のみのジョブで状態を読めなかった。利用者が直せないので異常にしない
        (.unknown(reason: "Can't read status"), false),
    ])
    func isAbnormal(status: ItemStatus, expected: Bool) {
        #expect(status.isAbnormal == expected)
    }

    /**
     詳細の見出し。理由があれば理由だけを出す。失敗は理由だけでは失敗と読めないことがあるので状態名を残す。
     Breaker が添えた補足は見出しに入れない（副行に回す）。通知とツールチップの全文では括弧で続ける
     */
    @Test(arguments: [
        (ItemStatus.ok, "Healthy", String?.none),
        (.running, "Running", nil),
        (.inactive(reason: "Disabled", note: ".plist.disabled"), "Disabled", "Disabled (.plist.disabled)"),
        (.failed(reason: "Exit code 1"), "Failed (Exit code 1)", "Exit code 1"),
        (.failed(reason: "Script not found", note: "~/bin/x.py"), "Failed (Script not found)", "Script not found (~/bin/x.py)"),
        (.failed(reason: "Didn't run as scheduled", note: "Sat, 10/31, 3:30 AM"), "Failed (Didn't run as scheduled)", "Didn't run as scheduled (Sat, 10/31, 3:30 AM)"),
        (.warning(reason: "Running from outside /Applications", note: "/tmp/A.app"), "Running from outside /Applications", "Running from outside /Applications (/tmp/A.app)"),
        (.unknown(reason: "Can't read status"), "Can't read status", "Can't read status"),
        (.warning(reason: "Folder not found", note: "it may not be mounted"), "Folder not found", "Folder not found (it may not be mounted)"),
        (.unknown(reason: "Can't read status", note: "boom"), "Can't read status", "Can't read status (boom)"),
    ])
    func summary(status: ItemStatus, summary: String, fullReason: String?) {
        #expect(status.summary == summary)
        #expect(status.fullReason == fullReason)
    }

    /// サイドバーの節の中の並び。正常と実行中、停止と未確認は同じ順にして、走り出すたびに行が動かないようにする
    @Test func sortOrderPutsFailuresFirst() {
        let statuses: [ItemStatus] = [.failed(reason: "Exit code 1"), .warning(reason: "x"), .ok, .running, .inactive(reason: "x"), .unknown(reason: "x")]
        #expect(statuses.map(\.sortOrder) == [0, 1, 2, 2, 3, 3])
    }
}
