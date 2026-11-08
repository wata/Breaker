import Foundation

/**
 失敗した項目を AI に調べさせるプロンプト。ジョブ名・定義・ログを手で集めて貼る手間を省く。
 本文は英語に固定してローカライズしない。AI は利用者の言語で答えるので、訳す必要がない
 */
enum AIPrompt {
    private static let logLineCount = 50

    /// `FileManager` を呼び出し元と同じメインアクターで使うためにメインアクターに置く。ログは `LogReader.tail` がメインアクターの外で読む
    @MainActor
    static func make(
        for item: MonitoredItem,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) async -> String {
        var sections = [String]()
        if let directory = workingDirectory(for: item, home: home, fileManager: fileManager) {
            // フォルダの URL のパスは末尾に `/` が付く。端末で打つ形にそろえる
            var path = directory.path(percentEncoded: false)
            if
                path.count > 1,
                path.hasSuffix("/")
            {
                path.removeLast()
            }
            sections.append("cd \(shellQuoted(path))")
        }
        sections.append("Breaker, a macOS app that monitors launchd jobs and cron jobs, reports a problem with the \(kindName(of: item)) below. Find the cause and suggest a fix.")
        sections.append(details(of: item, home: home, fileManager: fileManager).joined(separator: "\n"))
        sections.append(await logSection(of: logFiles(of: item)))
        return sections.joined(separator: "\n\n")
    }

    /**
     AI のコーディングツールを起動するフォルダ。スクリプトを直すことが多いので、スクリプトのあるリポジトリのルート、無ければスクリプトのフォルダ。
     スクリプトの無い launchd ジョブは plist のフォルダ。スクリプトの分からない cron の行は決められないので nil
     */
    static func workingDirectory(for item: MonitoredItem, home: URL, fileManager: FileManager) -> URL? {
        let script: URL?
        switch item.detail {
        case .launchdJob(let job):
            script = job.scriptURL(home: home, fileManager: fileManager)
            guard script != nil else {
                return job.plistURL.deletingLastPathComponent()
            }

        case .cronJob(let job):
            script = job.scriptURL(fileManager: fileManager)

        case .folderAction, .swiftBarPlugin, .monitoredApp, .sourceFailure:
            script = nil
        }
        guard let folder = script?.deletingLastPathComponent() else {
            return nil
        }
        return repositoryRoot(containing: folder, fileManager: fileManager) ?? folder
    }

    /// git を起動せずに `.git` のあるフォルダを上へたどる。worktree やサブモジュールの `.git` はファイルなので、種類を問わない
    private static func repositoryRoot(containing folder: URL, fileManager: FileManager) -> URL? {
        var current = folder.standardizedFileURL
        while true {
            if fileManager.fileExists(atPath: current.appending(path: ".git").path(percentEncoded: false)) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path(percentEncoded: false) != current.path(percentEncoded: false) else {
                return nil
            }
            current = parent
        }
    }

    private static func kindName(of item: MonitoredItem) -> String {
        switch item.kind {
        case .launchdJob:
            "launchd job"

        case .cronJob:
            "cron job"

        case .folderAction:
            "folder action"

        case .swiftBarPlugin:
            "SwiftBar plugin"

        case .monitoredApp:
            "app"
        }
    }

    /// 状態の理由と補足は画面と同じ言葉（利用者の言語）のまま渡す。AI には訳さなくても伝わる
    private static func details(of item: MonitoredItem, home: URL, fileManager: FileManager) -> [String] {
        var lines = ["Name: \(item.name)"]
        if let reason = item.status.reason {
            lines.append("Status: \(reason)")
        }
        if let note = item.status.note {
            lines.append("Status detail: \(note)")
        }
        switch item.detail {
        case .launchdJob(let job):
            lines.append("Label: \(job.label)")
            lines.append("plist: \(job.plistURL.path(percentEncoded: false))")
            if let destination = job.plistDestinationURL {
                lines.append("plist symlink target: \(destination.path(percentEncoded: false))")
            }
            lines.append("ProgramArguments: \(job.programArguments.map(shellQuoted).joined(separator: " "))")
            if let script = job.scriptURL(home: home, fileManager: fileManager) {
                lines.append("Script: \(script.path(percentEncoded: false))")
            }
            // 要約は画面では利用者の言語で出すが、ここは本文に合わせて英語にする
            lines.append("Schedule: \(job.schedule.summaryLines(locale: Locale(identifier: "en_US")).joined(separator: "; "))")
            if !job.environmentVariables.isEmpty {
                lines.append("EnvironmentVariables:")
                lines += job.environmentVariables.map { "  \($0.name)=\($0.value)" }
            }

        case .cronJob(let job):
            lines.append("crontab line: \(job.line)")
            if let script = job.scriptURL(fileManager: fileManager) {
                lines.append("Script: \(script.path(percentEncoded: false))")
            }

        case .folderAction, .swiftBarPlugin, .monitoredApp, .sourceFailure:
            break
        }
        return lines
    }

    private static func logFiles(of item: MonitoredItem) -> [MonitoredItem.LogFile] {
        switch item.detail {
        case .launchdJob(let job):
            job.logFiles

        case .cronJob(let job):
            job.logFiles

        case .folderAction, .swiftBarPlugin, .monitoredApp, .sourceFailure:
            []
        }
    }

    /// 無いログも書く。出力先のフォルダが無い・まだ一度も書かれていないことが原因の手がかりになる
    private static func logSection(of logs: [MonitoredItem.LogFile]) async -> String {
        guard !logs.isEmpty else {
            return "No log files are configured."
        }
        var sections = [String]()
        for log in logs {
            let heading = "\(logName(of: log.kind)): \(log.path)"
            do {
                guard let text = try await LogReader.tail(of: log.path, lineCount: logLineCount) else {
                    sections.append("\(heading) (not found)")
                    continue
                }
                sections.append(text.isEmpty ? "\(heading) (empty)" : "\(heading) (last \(logLineCount) lines)\n```\n\(text)\n```")
            } catch {
                sections.append("\(heading) (couldn't read: \(error.localizedDescription))")
            }
        }
        return sections.joined(separator: "\n\n")
    }

    /// `LogFile.title` は利用者の言語なので、本文に合わせた英語の名前を持つ
    private static func logName(of kind: MonitoredItem.LogFile.Kind) -> String {
        switch kind {
        case .combined:
            "Log"

        case .standardOutput:
            "Standard output log"

        case .standardError:
            "Standard error log"
        }
    }

    /// そのまま端末に貼って使えるよう、空白や記号を含むものだけを単一引用符で囲む
    static func shellQuoted(_ text: String) -> String {
        let plain = /[A-Za-z0-9_\-.,:\/@%+=~]+/
        guard text.wholeMatch(of: plain) == nil else {
            return text
        }
        return "'" + text.replacing("'", with: #"'\''"#) + "'"
    }
}
