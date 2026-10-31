import Foundation

struct SwiftBarError: LocalizedError {
    let message: String

    var errorDescription: String? {
        String(localized: "Couldn't get the SwiftBar plugin folder: \(message)")
    }
}

/// SwiftBar のプラグインフォルダにある実行ファイル
struct SwiftBarSource: ItemSource {
    let kind = MonitoredItem.Kind.swiftBarPlugin

    static let bundleID = "com.ameba.SwiftBar"

    private let shell: any ShellRunning
    private let runningApps: RunningApp.Provider
    private let homeDirectory: URL

    init(
        shell: any ShellRunning = ShellRunner(),
        runningApps: @escaping RunningApp.Provider = RunningApp.systemProvider,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.shell = shell
        self.runningApps = runningApps
        self.homeDirectory = homeDirectory
    }

    func items() async throws -> [MonitoredItem] {
        let output = try await shell.run("/usr/bin/defaults", arguments: ["read", Self.bundleID, "PluginDirectory"])
        guard let path = try Self.pluginDirectory(from: output) else {
            return []
        }
        let directory = URL(filePath: path.expandingTilde(home: homeDirectory), directoryHint: .isDirectory)
        // SwiftBar で選んだあとにフォルダを消した・移したときも、使っていないのと同じに扱う
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return []
        }
        let isAppRunning = await runningApps().contains { $0.bundleID == Self.bundleID }
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { url in
                let isExecutable = FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false))
                let requirements = ItemDescriptionReader.prefix(ofFileAt: url)
                    .flatMap(Self.interpreter(ofScript:))
                    .map { [HealthCheck.Requirement(kind: .interpreter, path: $0)] } ?? []
                return MonitoredItem(
                    key: url.path(percentEncoded: false),
                    name: url.lastPathComponent,
                    status: Self.status(
                        isAppRunning: isAppRunning,
                        isExecutable: isExecutable,
                        fileFailure: HealthCheck.fileFailure(in: requirements, home: homeDirectory) { HealthCheck.fileState(atPath: $0) }
                    ),
                    detail: .swiftBarPlugin(.init(fileURL: url, refreshInterval: Self.refreshInterval(fileName: url.lastPathComponent))),
                    autoDescription: ItemDescriptionReader.description(forScriptAt: url, home: homeDirectory)
                )
            }
    }
}

extension SwiftBarSource {
    private static let units: [Substring: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]

    /**
     SwiftBar を入れていない（設定が無い）ときの `defaults read` の stderr。macOS によって文言が違い、
     古いものは "The domain/default pair of (…) does not exist"、新しいものはドメインが無いと "Domain '…' not found."、
     キーだけが無いと "Could not find key '…' in domain '…'." を返す
     */
    private static let missingSettingMessages = ["does not exist", "Domain '\(bundleID)' not found", "Could not find key"]

    /// SwiftBar の設定が無いのは使っていないだけなので、異常にせず nil にする（CronSource の "no crontab for" と同じ扱い）
    static func pluginDirectory(from output: ShellOutput) throws -> String? {
        if output.status == 0 {
            return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if missingSettingMessages.contains(where: output.stderr.contains) {
            return nil
        }
        throw SwiftBarError(message: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// SwiftBar の命名規則 `name.{間隔}.{拡張子}`。間隔のないファイルは自動更新しない
    static func refreshInterval(fileName: String) -> TimeInterval? {
        let components = fileName.split(separator: ".")
        guard
            components.count >= 3,
            let match = components[components.count - 2].wholeMatch(of: /(?<value>\d+)(?<unit>[smhd])/),
            let value = TimeInterval(match.value),
            let unit = units[match.unit]
        else {
            return nil
        }
        return value * unit
    }

    /// シバンの絶対パスのインタプリタ。`#!/usr/bin/env python3` は PATH を引かないと分からないので見ない
    static func interpreter(ofScript script: String) -> String? {
        guard
            let line = script.split(separator: "\n", maxSplits: 1).first,
            line.hasPrefix("#!"),
            let path = line.dropFirst(2).split(separator: " ").first.map(String.init),
            path.hasPrefix("/"),
            path != "/usr/bin/env"
        else {
            return nil
        }
        return path
    }

    /**
     実行できない・インタプリタが無いプラグインは SwiftBar が動かせないので失敗。
     SwiftBar を終了しているのは利用者が止めたこともあり、起動すれば動くので要確認のままにする
     */
    static func status(isAppRunning: Bool, isExecutable: Bool, fileFailure: ItemStatus? = nil) -> ItemStatus {
        if !isAppRunning {
            return .warning(reason: String(localized: "SwiftBar isn't running"))
        }
        if !isExecutable {
            return .failed(reason: String(localized: "No permission to execute"))
        }
        return fileFailure ?? .ok
    }
}
