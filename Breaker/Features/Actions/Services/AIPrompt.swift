import Foundation

/**
 失敗した項目を AI に調べさせるプロンプト。ジョブ名・定義・ログを手で集めて貼る手間を省く。
 ネットワーク・負荷・ストレージは正常でも聞けるので、異常が無ければ問題の調査ではなく今の状態の見立てを頼む。
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
        sections.append(request(for: item))
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

        case .folderAction, .network, .systemLoad, .storage, .sourceFailure:
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

    private static func request(for item: MonitoredItem) -> String {
        let app = "Breaker, a macOS app that monitors launchd jobs, cron jobs, the network, CPU load and storage,"
        if item.status.isAbnormal {
            return "\(app) reports a problem with the \(kindName(of: item)) below. Find the cause and suggest a fix."
        } else {
            return "\(app) shows the current state of the \(kindName(of: item)) below. Point out anything unusual, explain the likely cause, and suggest what to check or do."
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

        case .network:
            "network health check"

        case .systemLoad:
            "system load check"

        case .storage:
            "storage check"
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

        case .network(let health):
            lines += networkDetails(of: health)

        case .systemLoad(let load):
            lines += systemLoadDetails(of: load)

        case .storage(let usage):
            lines += storageDetails(of: usage)

        case .folderAction, .sourceFailure:
            break
        }
        return lines
    }

    /// 値の書式は画面と同じものを使い、言語だけ本文に合わせて英語にする
    private static let english = Locale(identifier: "en_US")

    private static func networkDetails(of health: NetworkHealth) -> [String] {
        var lines = [
            "Connection: \(health.pathStatus.title), \(health.interface.title)\(health.isExpensive ? ", expensive" : "")\(health.isConstrained ? ", Low Data Mode" : "")",
            "Router: \(health.routerAddress ?? "unknown")",
            "DNS servers: \(health.dnsServers.isEmpty ? "none" : health.dnsServers.joined(separator: ", "))",
        ]
        for ping in [health.routerPing, health.internetPing].compactMap({ $0 }) {
            let average = ping.averageMilliseconds.map { NetworkHealth.latencyText(milliseconds: $0, locale: english) } ?? "no reply"
            lines.append("Ping \(ping.destination): \(average), \(NetworkHealth.packetLossText(ping.lossRate, locale: english))")
        }
        if let lookup = health.dnsLookup {
            lines.append("DNS lookup: \(lookup.title(locale: english))\(lookup.failureReason.map { " (\($0))" } ?? "")")
        }
        if let access = health.internetAccess {
            lines.append("Internet access: \(access.title)\(access.failureReason.map { " (\($0))" } ?? "")")
        }
        if let wifi = health.wifi {
            let details = [wifi.bandText(locale: english), wifi.standardText(locale: english)].compactMap { $0 }.joined(separator: ", ")
            lines.append("Wi-Fi: signal \(NetworkHealth.powerText(decibelMilliwatts: wifi.rssi, locale: english)), noise \(NetworkHealth.powerText(decibelMilliwatts: wifi.noise, locale: english)), channel \(wifi.channelText(locale: english)), \(details), transmit rate \(NetworkHealth.speedText(megabitsPerSecond: wifi.transmitRate, locale: english))")
        }
        if let speed = health.lastSpeedTest?.speed {
            lines.append("Last speed test: down \(NetworkHealth.speedText(bitsPerSecond: speed.downloadBitsPerSecond, locale: english)), up \(NetworkHealth.speedText(bitsPerSecond: speed.uploadBitsPerSecond, locale: english))")
        }
        return lines
    }

    /// CPU の % の基準（1コア＝100%）とコア数を書き添え、全体に対する割合と取り違えさせない
    private static func systemLoadDetails(of load: SystemLoad) -> [String] {
        var lines = [
            "CPU (100% = one core, \(load.coreCount) cores): \(SystemLoad.percentText(load.cpuPercent, locale: english))",
            "Load average (1 min): \(load.loadAverage.formatted(.number.precision(.fractionLength(1)).locale(english)))",
            "Thermal state: \(load.thermalState)",
            "Memory pressure: \(load.memoryPressure)",
            "Top processes, grouped by app (100% = one core):",
        ]
        lines += load.consumers.prefix(SystemLoad.listedConsumerCount).map { consumer in
            "  \(consumer.name): \(SystemLoad.percentText(consumer.cpuPercent, locale: english))\(consumer.bundlePath.map { " (\($0))" } ?? "")"
        }
        if let since = load.culprit.flatMap({ LoadCheck.sinceDate(of: $0, in: load.history) }) {
            lines.append("High usage started: \(since.formatted(.iso8601))")
        }
        return lines
    }

    private static func storageDetails(of usage: StorageUsage) -> [String] {
        var lines = [
            "Startup disk: \(StorageUsage.bytesText(usage.availableBytes, locale: english)) available of \(StorageUsage.bytesText(usage.capacityBytes, locale: english))",
        ]
        guard let scan = usage.scan else {
            return lines
        }
        lines.append("Sizes of folders that often grow (measured \(scan.date.formatted(.iso8601))\(scan.previousDate.map { ", compared with \($0.formatted(.iso8601))" } ?? "")):")
        lines += scan.locations.map { location in
            let growth = location.growthBytes.map { ", \($0 >= 0 ? "+" : "-")\(StorageUsage.bytesText(abs($0), locale: english)) since previous" } ?? ""
            return "  \(location.path): \(StorageUsage.bytesText(location.bytes, locale: english))\(growth)"
        }
        return lines
    }

    private static func logFiles(of item: MonitoredItem) -> [MonitoredItem.LogFile] {
        switch item.detail {
        case .launchdJob(let job):
            job.logFiles

        case .cronJob(let job):
            job.logFiles

        case .folderAction, .network, .systemLoad, .storage, .sourceFailure:
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
