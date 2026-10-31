import Foundation

/// ログ末尾の読み出し。数 MB あるログもあるので、末尾の一定量だけを読む
enum LogReader {
    /// 200 行に十分な量。1行が長いログでも読み込みが重くならない上限
    private static let maxBytes: UInt64 = 256 * 1024

    /**
     色（`ESC[31m`）や行消去（`ESC[2K`）などの CSI、リンク（`ESC]8;;url ESC\`）などの OSC、それ以外の2文字の ESC 列。
     文字単位で照合すると、終端の文字と直後の結合文字が1文字にまとまって取り残されることがあるので、Unicode スカラー単位で照合する。
     `Regex` は Sendable でなく static let にできないので、ファイルを読むたびに作る
     */
    private static var escapeSequence: Regex<Substring> {
        #/\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[ -/]*[0-~])/#
            .matchingSemantics(RegexSemanticLevel.unicodeScalar)
    }

    /// ファイルがなければ nil。メインスレッドを止めないよう、呼び出し元のアクターから外して読む
    @concurrent
    static func tail(of path: String, lineCount: Int) async throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let handle = try FileHandle(forReadingFrom: URL(filePath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = size > maxBytes ? size - maxBytes : 0
        try handle.seek(toOffset: offset)
        let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        return lastLines(of: plainText(of: text), count: lineCount, startsMidLine: offset > 0)
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

    /**
     端末で見えるとおりの文字にする。ログ本文・サイドバーの補足・通知・エラー行の判定はみな `tail` で読んだ文字を使うので、読んだ時点で一度だけ落とす。
     色は出さずに捨てる。`\r` は進捗表示が同じ行を上書きするのに使うので、行のうち最後の `\r` より後だけを残す。
     `\r\n` は Swift では1文字なので、先に `\n` にしておかないと行に分かれず、上書きの扱いも誤る。
     256KB でも数十ミリ秒で済み、ESC も `\r` も無いログはそのまま返す
     */
    static func plainText(of text: String) -> String {
        let unescaped = text.unicodeScalars.contains("\u{1B}") ? text.replacing(escapeSequence, with: "") : text
        guard unescaped.unicodeScalars.contains("\r") else {
            return unescaped
        }
        return unescaped.replacing("\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "\r").last ?? "" }
            .joined(separator: "\n")
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
