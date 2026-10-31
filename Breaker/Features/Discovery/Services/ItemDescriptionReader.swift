import Foundation

/**
 項目が何のためのものかを、スクリプト自身のヘッダーかそれを含むプロジェクトの README から1文で取り出す。
 取れなければ nil（利用者のメモで補う）
 */
enum ItemDescriptionReader {
    /// ヘッダーとメタデータは先頭にある。`~/bin` の実行ファイルがバイナリでも読み込みが重くならない上限
    private static let maxScriptBytes = 64 * 1024
    private static let readmeName = "README.md"
    /// 起動用のラッパーだという説明は用途ではないので、プロジェクトの README に任せる
    private static let wrapperWords = ["ラッパー", "wrapper", "launcher"]

    static func description(forScriptAt url: URL, home: URL) -> String? {
        prefix(ofFileAt: url).flatMap(headerDescription(ofScript:))
            ?? readmeSummary(above: url.deletingLastPathComponent(), home: home)
    }

    /**
     SwiftBar のメタデータを優先し、なければシバン直後のコメントブロックの最初の1文。
     シバンのないファイルの先頭コメントは用途の説明とは限らない（`connect.3s.sh` は PATH の説明）ので見ない
     */
    static func headerDescription(ofScript script: String) -> String? {
        if let match = script.firstMatch(of: /<(?<key>xbar|swiftbar)\.desc>(?<text>.*?)<\/\k<key>\.desc>/) {
            let text = match.text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        let lines = trimmedLines(of: script)
        guard lines.first?.hasPrefix("#!") == true else {
            return nil
        }
        let comment = commentLines(after: lines.dropFirst())
        // `# auto-fix-launcher.sh` のように自分のファイル名を書いただけの行は説明ではない
        guard let line = comment.first(where: { !$0.isEmpty && $0.wholeMatch(of: /[\w.-]+\.\w+/) == nil }) else {
            return nil
        }
        let sentence = firstSentence(of: line)
        let lowercased = sentence.lowercased()
        return wrapperWords.contains { lowercased.contains($0) } ? nil : sentence
    }

    /// H1 直後の段落の最初の1文を `<H1>: <文>` で返す。H1 の次が見出しや表・リスト・コードだけなら nil
    static func summary(ofReadme readme: String) -> String? {
        let lines = trimmedLines(of: readme)
        guard let titleIndex = lines.firstIndex(where: { $0.hasPrefix("# ") }) else {
            return nil
        }
        let title = lines[titleIndex].dropFirst(2).trimmingCharacters(in: .whitespaces)
        var paragraph = [String]()
        var isInCodeBlock = false
        for line in lines[(titleIndex + 1)...] {
            if line.hasPrefix("```") {
                isInCodeBlock.toggle()
                continue
            }
            if isInCodeBlock {
                continue
            }
            if line.hasPrefix("#") || (line.isEmpty && !paragraph.isEmpty) {
                break
            }
            if line.isEmpty || !isParagraphLine(line) {
                // 段落の途中に表やリストが来たら、そこまでを段落とする
                if !paragraph.isEmpty {
                    break
                }
                continue
            }
            paragraph.append(line)
        }
        guard !paragraph.isEmpty else {
            return nil
        }
        return "\(title): \(firstSentence(of: paragraph.joined(separator: " ")))"
    }
}

extension ItemDescriptionReader {
    /// SwiftBar のシバンの確認でも使う
    static func prefix(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: maxScriptBytes)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func trimmedLines(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `#` 行の連続か Python の docstring。シバンの次の行から始まっていなければ空
    private static func commentLines(after lines: ArraySlice<String>) -> [String] {
        guard let first = lines.first else {
            return []
        }
        if let quote = ["\"\"\"", "'''"].first(where: { first.hasPrefix($0) }) {
            var docstring = [String]()
            for (index, line) in lines.enumerated() {
                let body = index == 0 ? String(line.dropFirst(quote.count)) : line
                if let end = body.range(of: quote) {
                    docstring.append(body[..<end.lowerBound].trimmingCharacters(in: .whitespaces))
                    break
                }
                docstring.append(body.trimmingCharacters(in: .whitespaces))
            }
            return docstring
        }
        return lines
            .prefix { $0.hasPrefix("#") }
            .map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
    }

    /// 文の区切りは「。」か「. 」。区切りがなければ（1文目が改行で終わる）その行全体
    private static func firstSentence(of text: String) -> String {
        let candidates = [text.range(of: "。")?.upperBound, text.range(of: ". ").map { text.index(after: $0.lowerBound) }]
        guard let end = candidates.compactMap({ $0 }).min() else {
            return text
        }
        return String(text[..<end])
    }

    /// 表・リスト・画像バッジ・HTML は紹介文ではない
    private static func isParagraphLine(_ line: String) -> Bool {
        let nonParagraphPrefixes = ["|", "- ", "* ", "+ ", ">", "<", "![", "[!["]
        return !nonParagraphPrefixes.contains { line.hasPrefix($0) } && line.wholeMatch(of: /\d+\.\s.*/) == nil
    }

    /**
     スクリプトのある場所から上へたどる。サブディレクトリの README（`scripts/README.md` など）は
     H1 の直後が見出しで紹介文がないことが多いので、要約が取れた最初の README を使う。
     git のルートより上は別のプロジェクトなので見ない。ホームの README も個々の項目とは関係ない
     */
    private static func readmeSummary(above directory: URL, home: URL) -> String? {
        let fileManager = FileManager.default
        let homePath = home.standardizedFileURL.path(percentEncoded: false)
        var current = directory.standardizedFileURL
        while current.path(percentEncoded: false) != homePath {
            let readmeURL = current.appending(path: readmeName)
            if
                let readme = try? String(contentsOf: readmeURL, encoding: .utf8),
                let summary = summary(ofReadme: readme)
            {
                return summary
            }
            let parent = current.deletingLastPathComponent()
            if fileManager.fileExists(atPath: current.appending(path: ".git").path(percentEncoded: false)) || parent == current {
                return nil
            }
            current = parent
        }
        return nil
    }
}
