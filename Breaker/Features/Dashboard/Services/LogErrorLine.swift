import Foundation

/**
 ログの中から失敗の原因らしい行を見分ける。詳細の概要に出す原因の1行と、ログ本文で地を敷く行に同じ判定を使う。
 語を含むかどうかだけで見るので、「0 failed」のような行も拾う。原因の候補を見落とすよりは、余分に拾うほうを選んでいる
 */
enum LogErrorLine {
    /// 大文字小文字は区別しない
    private static let keywords = ["error", "exception", "fatal", "failed", "エラー", "失敗"]
    private static let tracebackHeader = "Traceback (most recent call last)"

    /**
     Python の例外は最後の行が `KeyboardInterrupt` のように語を含まないことがあるので、Traceback の後の
     字下げされていない最初の行（例外の型とメッセージ）もエラーとする。字下げされたスタックの各段は、
     ファイル名に `error` を含んでいても原因ではないので拾わない
     */
    static func flags(of lines: [Substring]) -> [Bool] {
        var isInTraceback = false
        return lines.map { line in
            if line.hasPrefix(tracebackHeader) {
                isInTraceback = true
                return false
            }
            guard isInTraceback else {
                return containsKeyword(line)
            }
            if line.first.map(\.isWhitespace) ?? true {
                return false
            } else {
                isInTraceback = false
                return true
            }
        }
    }

    /// 最後のエラー行。原因はたいてい最後に出るので、それより前のエラー行は使わない
    static func last(in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let flags = flags(of: lines)
        return lines.indices
            .last { flags[$0] }
            .map { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func containsKeyword(_ line: Substring) -> Bool {
        keywords.contains { line.range(of: $0, options: .caseInsensitive) != nil }
    }
}
