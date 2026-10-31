import Testing
@testable import Breaker

struct LogErrorLineTests {
    @Test(arguments: [
        ("ERROR: connection refused", true),
        ("RuntimeError: BigQuery の認証が切れています", true),
        ("Unhandled Exception in thread main", true),
        ("fatal: not a git repository", true),
        ("Build FAILED", true),
        ("認証エラーで止まりました", true),
        ("送信に失敗しました", true),
        ("2026-10-29 09:00:01 [daily-sales-report] step 1 done", false),
        ("stderr を閉じました", false),
        ("", false),
    ])
    func keyword(line: String, expected: Bool) {
        #expect(LogErrorLine.flags(of: [Substring(line)]) == [expected])
    }

    /// スタックの段はファイル名に error を含んでも拾わず、例外の行は語を含まなくても拾う
    @Test func tracebackFlagsOnlyExceptionLine() {
        let lines: [Substring] = [
            "Traceback (most recent call last):",
            "  File \"/Users/me/error_handler.py\", line 3, in <module>",
            "    main()",
            "",
            "KeyboardInterrupt",
            "step 2 done",
        ]
        #expect(LogErrorLine.flags(of: lines) == [false, false, false, false, true, false])
    }

    @Test func lastPicksLatestErrorLineAndTrims() {
        let text = "ERROR: first\nstep 1 done\n  RuntimeError: second  \nstep 2 done\n"
        #expect(LogErrorLine.last(in: text) == "RuntimeError: second")
    }

    @Test func lastPicksExceptionAfterTraceback() {
        let text = "step 1 done\nTraceback (most recent call last):\n  File \"a.py\", line 1, in <module>\nKeyboardInterrupt"
        #expect(LogErrorLine.last(in: text) == "KeyboardInterrupt")
    }

    /// 色付きの Traceback も、LogReader で色を落とせば見出しと例外の行が分かる
    @Test func lastPicksExceptionAfterColoredTraceback() {
        let text = "\u{1B}[31mTraceback (most recent call last):\u{1B}[0m\n  File \"a.py\", line 1, in <module>\n\u{1B}[1;31mKeyboardInterrupt\u{1B}[0m"
        #expect(LogErrorLine.last(in: LogReader.plainText(of: text)) == "KeyboardInterrupt")
    }

    @Test func lastIsNilWithoutErrors() {
        #expect(LogErrorLine.last(in: "step 1 done\nstep 2 done") == nil)
        #expect(LogErrorLine.last(in: "") == nil)
    }
}
