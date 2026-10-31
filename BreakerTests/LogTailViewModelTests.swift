import Foundation
import Testing
@testable import Breaker

@MainActor
struct LogTailViewModelTests {
    /// 時刻を書き戻したときに小数の丸めで目印がずれないよう、秒ちょうどの時刻を使う
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func loadsTail() async throws {
        let directory = try TemporaryDirectory()
        let path = try writeLog("step 1", in: directory)
        let viewModel = LogTailView.ViewModel()

        await viewModel.load(path: path, lineCount: 200)

        #expect(viewModel.content == .text("step 1"))
    }

    /// 更新時刻も大きさも変わっていなければ中身を読まない。同じ大きさで書き換えて時刻を戻し、前の内容のままであることで確かめる
    @Test func skipsReadingWhenFileIsUnchanged() async throws {
        let directory = try TemporaryDirectory()
        let path = try writeLog("step 1", in: directory)
        try setModificationDate(Self.date, of: path)
        let viewModel = LogTailView.ViewModel()
        await viewModel.load(path: path, lineCount: 200)

        try "step 2".write(toFile: path, atomically: false, encoding: .utf8)
        try setModificationDate(Self.date, of: path)
        await viewModel.load(path: path, lineCount: 200)

        #expect(viewModel.content == .text("step 1"))
    }

    @Test func reloadsWhenFileGrows() async throws {
        let directory = try TemporaryDirectory()
        let path = try writeLog("step 1", in: directory)
        try setModificationDate(Self.date, of: path)
        let viewModel = LogTailView.ViewModel()
        await viewModel.load(path: path, lineCount: 200)

        // 更新時刻の分解能より短い間の追記でも、大きさで気づく
        try "step 1\nstep 2".write(toFile: path, atomically: false, encoding: .utf8)
        try setModificationDate(Self.date, of: path)
        await viewModel.load(path: path, lineCount: 200)

        #expect(viewModel.content == .text("step 1\nstep 2"))
    }

    @Test func reloadsWhenModificationDateChanges() async throws {
        let directory = try TemporaryDirectory()
        let path = try writeLog("step 1", in: directory)
        try setModificationDate(Self.date, of: path)
        let viewModel = LogTailView.ViewModel()
        await viewModel.load(path: path, lineCount: 200)

        try "step 2".write(toFile: path, atomically: false, encoding: .utf8)
        try setModificationDate(Self.date.addingTimeInterval(1), of: path)
        await viewModel.load(path: path, lineCount: 200)

        #expect(viewModel.content == .text("step 2"))
    }

    /// 出力を切り替えたら、目印がたまたま同じでも別のファイルとして読む
    @Test func reloadsWhenPathChanges() async throws {
        let directory = try TemporaryDirectory()
        let out = try writeLog("out", in: directory, name: "out.log")
        let err = try writeLog("err", in: directory, name: "err.log")
        try setModificationDate(Self.date, of: out)
        try setModificationDate(Self.date, of: err)
        let viewModel = LogTailView.ViewModel()

        await viewModel.load(path: out, lineCount: 200)
        await viewModel.load(path: err, lineCount: 200)

        #expect(viewModel.content == .text("err"))
    }

    /// まだ無いファイルは、作られたら読む
    @Test func readsFileOnceItAppears() async throws {
        let directory = try TemporaryDirectory()
        let path = directory.url.appending(path: "job.log").path(percentEncoded: false)
        let viewModel = LogTailView.ViewModel()
        await viewModel.load(path: path, lineCount: 200)
        #expect(viewModel.content == .missing)

        try "started".write(toFile: path, atomically: false, encoding: .utf8)
        await viewModel.load(path: path, lineCount: 200)

        #expect(viewModel.content == .text("started"))
    }

    /// 取り消されたら眠りの途中でも戻り、読み直しを続けない
    @Test func followStopsWhenCancelled() async throws {
        let directory = try TemporaryDirectory()
        let path = try writeLog("step 1", in: directory)
        let viewModel = LogTailView.ViewModel()
        let task = Task { await viewModel.follow(path: path, lineCount: 200) }

        task.cancel()
        await task.value

        #expect(viewModel.content == .loading)
    }

    private func writeLog(_ text: String, in directory: borrowing TemporaryDirectory, name: String = "job.log") throws -> String {
        let path = directory.url.appending(path: name).path(percentEncoded: false)
        try text.write(toFile: path, atomically: false, encoding: .utf8)
        return path
    }

    private func setModificationDate(_ date: Date, of path: String) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }
}
