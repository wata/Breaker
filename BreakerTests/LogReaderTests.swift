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
