import Foundation
import Testing
@testable import Breaker

struct LogReaderTests {
    @Test func keepsLastLinesWithoutTrailingEmptyLine() {
        #expect(LogReader.lastLines(of: "a\nb\nc\n", count: 2) == "b\nc")
        #expect(LogReader.lastLines(of: "a\nb", count: 5) == "a\nb")
        #expect(LogReader.lastLines(of: "", count: 5) == "")
    }

    @Test func dropsPartialFirstLineWhenReadFromMiddle() {
        #expect(LogReader.lastLines(of: "tial\nb\nc", count: 5, startsMidLine: true) == "b\nc")
    }

    @Test func plainTextRemovesEscapeSequences() {
        #expect(LogReader.plainText(of: "\u{1B}[1;31mERROR\u{1B}[0m: boom") == "ERROR: boom")
        #expect(LogReader.plainText(of: "\u{1B}[2Kdone\u{1B}(B") == "done")
        #expect(LogReader.plainText(of: "see \u{1B}]8;;https://example.com\u{1B}\\docs\u{1B}]8;;\u{07} now") == "see docs now")
    }

    /// 進捗表示は最後に上書きした内容だけが残り、`\r\n` の行は普通の行として分かれる
    @Test func plainTextKeepsTextAfterLastCarriageReturn() {
        #expect(LogReader.plainText(of: "10%\r50%\r100%\nnext") == "100%\nnext")
        #expect(LogReader.plainText(of: "a\r\nb\r\n") == "a\nb\n")
    }

    @Test func plainTextLeavesPlainTextUnchanged() {
        let text = "2026-10-29 09:00:01 [daily] step 1 done\n認証エラー [x] ~/a-b\n\n"
        #expect(LogReader.plainText(of: text) == text)
    }

    @Test func tailRemovesEscapeSequences() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "job.log")
        try "\u{1B}[32mstep 1 done\u{1B}[0m\r\n\u{1B}[31mRuntimeError: boom\u{1B}[0m\r\n".write(to: url, atomically: true, encoding: .utf8)

        let tail = try await LogReader.tail(of: url.path(percentEncoded: false), lineCount: 200)
        #expect(tail == "step 1 done\nRuntimeError: boom")
    }

    @Test func readsTailOfFile() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "job.log")
        try (1...300).map { "line \($0)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let tail = try #require(try await LogReader.tail(of: url.path(percentEncoded: false), lineCount: 200))
        let lines = tail.split(separator: "\n")
        #expect(lines.count == 200)
        #expect(lines.first == "line 101")
        #expect(lines.last == "line 300")
    }

    @Test func missingFileIsNil() async throws {
        let tail = try await LogReader.tail(of: "/nonexistent/Breaker.log", lineCount: 10)
        #expect(tail == nil)
    }
}
