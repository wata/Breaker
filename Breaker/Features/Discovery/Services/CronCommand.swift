import Foundation

/**
 crontab の行のコマンドから、名前・静的チェック・ログに使う部分を取り出したもの。
 cron はコマンドを `/bin/sh -c` に渡すので、シェルの語の区切り（引用符・`\`）とリダイレクトだけを真似る。
 `/bin/sh -c "…"` の文字列の中はシェルが後で解釈するものなので見ない
 */
struct CronCommand: Hashable, Sendable {
    /// 最初の語（先頭の `NAME=value` は飛ばす）。絶対パスか `~/` のときだけ（PATH は引かない）
    let executable: String?
    /// 最初のパス（`/` を含む語）。書かれたままのもの
    let firstPath: String?
    /// `firstPath` を `~` の展開と、cron の作業フォルダ（ホーム）からの相対で解決したもの
    let resolvedFirstPath: String?
    /// 標準出力のリダイレクト先。`/dev/null`・変数を含むなど、ファイルが分からないときは nil
    let standardOutPath: String?
    let standardErrorPath: String?

    private enum Token: Equatable {
        case word(String)
        /// `>`・`>>`・`2>` など。続く語が行き先
        case redirect(descriptor: Int)
        /// `&>`・`&>>`。標準出力と標準エラーの両方
        case redirectBoth
        /// `2>&1` など
        case duplicate(from: Int, to: Int?)
        /// `<`。続く語は入力なので名前やパスに数えない
        case input
        case separator
    }

    init(_ command: String, home: URL) {
        var words: [String] = []
        var outputs: [Int: String] = [:]
        var pending: Token?
        for token in Self.tokens(of: Self.shellPart(of: command)) {
            switch token {
            case .word(let word):
                switch pending {
                case .redirect(let descriptor):
                    outputs[descriptor] = word

                case .redirectBoth:
                    outputs[1] = word
                    outputs[2] = word

                case .input:
                    break

                default:
                    words.append(word)
                }
                pending = nil

            case .duplicate(let from, let to):
                // `>> log 2>&1` は標準エラーも log へ、`2>&1 >> log` は元の標準出力（cron のメール）へ。書いた順に追う
                outputs[from] = to.flatMap { outputs[$0] }
                pending = nil

            case .redirect, .redirectBoth, .input:
                pending = token

            case .separator:
                pending = nil
            }
        }
        executable = words
            .first { $0.firstMatch(of: /^[A-Za-z_][A-Za-z0-9_]*=/) == nil }
            .flatMap { $0.hasPrefix("/") || Self.isHomePath($0) ? Self.resolvedPath($0, home: home) : nil }
        firstPath = words.first { $0.contains("/") }
        resolvedFirstPath = firstPath.flatMap { Self.resolvedPath($0, home: home) }
        standardOutPath = outputs[1].flatMap { Self.resolvedPath($0, home: home) }.flatMap { $0 == "/dev/null" ? nil : $0 }
        standardErrorPath = outputs[2].flatMap { Self.resolvedPath($0, home: home) }.flatMap { $0 == "/dev/null" ? nil : $0 }
    }

    private static func isHomePath(_ word: String) -> Bool {
        word.hasPrefix("~/") || word.hasPrefix("$HOME/") || word.hasPrefix("${HOME}/")
    }

    /**
     `~/`・`$HOME/` を展開し、相対パスは cron の作業フォルダ（ホーム）から解決する。
     ほかの変数やコマンド置換を含む・`~user` のように書かれたものは、実行時にしか分からないので nil
     */
    static func resolvedPath(_ word: String, home: URL) -> String? {
        let path = word.replacing(/^\$HOME\//, with: "~/").replacing(/^\$\{HOME\}\//, with: "~/")
        guard
            !path.isEmpty,
            !path.contains("$"),
            !path.contains("`"),
            !path.hasPrefix("~") || path.hasPrefix("~/")
        else {
            return nil
        }
        if path.hasPrefix("/") || path.hasPrefix("~/") {
            return path.expandingTilde(home: home)
        } else {
            return home.path(percentEncoded: false).trimmingSuffix("/") + "/" + path
        }
    }

    /// cron は最初の `\` の付かない `%` から後ろを標準入力に回し、`\%` を `%` に戻してシェルに渡す
    static func shellPart(of command: String) -> String {
        var result = ""
        var isEscaped = false
        for character in command {
            if isEscaped {
                result.append(character == "%" ? "%" : "\\\(character)")
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if character == "%" {
                break
            }
            result.append(character)
        }
        if isEscaped {
            result.append("\\")
        }
        return result
    }

    private static let operatorCharacters: Set<Character> = ["|", ";", "&", "<", ">", "(", ")"]

    private static func tokens(of command: String) -> [Token] {
        let characters = Array(command)
        var tokens: [Token] = []
        var index = 0
        func character(at offset: Int) -> Character? {
            offset < characters.count ? characters[offset] : nil
        }
        while index < characters.count {
            let current = characters[index]
            if current.isWhitespace {
                index += 1
                continue
            }
            if current == "&" {
                if character(at: index + 1) == ">" {
                    index += character(at: index + 2) == ">" ? 3 : 2
                    tokens.append(.redirectBoth)
                } else {
                    index += character(at: index + 1) == "&" ? 2 : 1
                    tokens.append(.separator)
                }
                continue
            }
            if "|;()".contains(current) {
                index += 1
                tokens.append(.separator)
                continue
            }
            if current == "<" {
                index += 1
                tokens.append(.input)
                continue
            }
            var end = index
            while character(at: end)?.isNumber == true {
                end += 1
            }
            if character(at: end) == ">" {
                let descriptor = end > index ? Int(String(characters[index..<end])) ?? 1 : 1
                end += 1
                if character(at: end) == ">" || character(at: end) == "|" {
                    end += 1
                }
                if character(at: end) == "&" {
                    end += 1
                    var targetEnd = end
                    while character(at: targetEnd)?.isNumber == true {
                        targetEnd += 1
                    }
                    let target = Int(String(characters[end..<targetEnd]))
                    if character(at: targetEnd) == "-" {
                        targetEnd += 1
                    }
                    tokens.append(.duplicate(from: descriptor, to: target))
                    index = targetEnd
                } else {
                    tokens.append(.redirect(descriptor: descriptor))
                    index = end
                }
                continue
            }
            let (word, next) = word(in: characters, from: index)
            tokens.append(.word(word))
            index = next
        }
        return tokens
    }

    /// 引用符を外した1語と、その次の位置
    private static func word(in characters: [Character], from start: Int) -> (String, Int) {
        var word = ""
        var index = start
        while index < characters.count {
            let current = characters[index]
            if current.isWhitespace || operatorCharacters.contains(current) {
                break
            }
            switch current {
            case "'":
                index += 1
                while index < characters.count, characters[index] != "'" {
                    word.append(characters[index])
                    index += 1
                }

            case "\"":
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    if
                        characters[index] == "\\",
                        index + 1 < characters.count,
                        "\"\\$`".contains(characters[index + 1])
                    {
                        index += 1
                    }
                    word.append(characters[index])
                    index += 1
                }

            case "\\":
                index += 1
                if index < characters.count {
                    word.append(characters[index])
                }

            default:
                word.append(current)
            }
            index += 1
        }
        return (word, index)
    }
}
