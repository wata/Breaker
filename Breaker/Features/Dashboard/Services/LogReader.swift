import Foundation

/// ログ末尾の読み出し。数 MB あるログもあるので、末尾の一定量だけを読む
enum LogReader {
    /// 200 行に十分な量。1行が長いログでも読み込みが重くならない上限
    private static let maxBytes: UInt64 = 256 * 1024

    /// ファイルがなければ nil。メインスレッドを止めないよう、呼び出し元のアクターから外して読む
    @concurrent
    static func tail(of path: String, lineCount: Int) async throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let handle = try FileHandle(forReadingFrom: URL(filePath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = size > maxBytes ? size - maxBytes : 0
        try handle.seek(toOffset: offset)
        let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        return lastLines(of: text, count: lineCount, startsMidLine: offset > 0)
    }

    /// 渡した順に末尾を読む。無いファイル・読めないファイルは飛ばす
    static func tails(of paths: [String], lineCount: Int) async -> [String] {
        var logs: [String] = []
        for path in paths {
            guard let text = try? await tail(of: path, lineCount: lineCount) else { continue }
            logs.append(text)
        }
        return logs
    }

    /// ログのうちいちばん新しい更新時刻。どれも無ければ nil
    static func lastModificationDate(of paths: [String]) -> Date? {
        paths
            .compactMap { try? URL(filePath: $0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }

    /// 途中から読んだときは先頭の行が欠けているので捨てる。末尾の改行で空行が1つ増えないようにする
    static func lastLines(of text: String, count: Int, startsMidLine: Bool = false) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if startsMidLine {
            lines.removeFirst()
        }
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.suffix(count).joined(separator: "\n")
    }
}
