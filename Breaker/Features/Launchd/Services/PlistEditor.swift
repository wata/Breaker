import Foundation

enum PlistEditorError: LocalizedError, Equatable {
    case unreadable(URL)
    case lintFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            String(localized: "Couldn't read \(url.path(percentEncoded: false).abbreviatingHome) as a plist")

        case .lintFailed(let message):
            String(localized: "The save was canceled because the written plist didn't pass plutil -lint: \(message)")
        }
    }
}

/**
 launchd plist のスケジュール（StartCalendarInterval / StartInterval）だけを書き換える。
 シンボリックリンク（リポジトリで管理している plist をリンクしたもの）はリンク先を書き換え、リンクは残す。
 `JobActions` と同じく `FileManager` が Sendable でないので、メインアクターで扱う
 */
@MainActor
struct PlistEditor {
    static let defaultBackupDirectory = URL.applicationSupportDirectory.appending(path: "Breaker/backups", directoryHint: .isDirectory)

    private static let plutil = "/usr/bin/plutil"

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private let launchctl: LaunchctlService
    private let shell: any ShellRunning
    private let backupDirectory: URL
    private let fileManager: FileManager

    init(
        launchctl: LaunchctlService = LaunchctlService(),
        shell: any ShellRunning = ShellRunner(),
        backupDirectory: URL = Self.defaultBackupDirectory,
        fileManager: FileManager = .default
    ) {
        self.launchctl = launchctl
        self.shell = shell
        self.backupDirectory = backupDirectory
        self.fileManager = fileManager
    }

    /// `PropertyListSerialization` は XML コメントを読み捨てるので、書き出すと消える。保存前に警告するために調べる
    static func containsComments(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.resolvingSymlinksInPath()) else {
            return false
        }
        return String(decoding: data, as: UTF8.self).contains("<!--")
    }

    /**
     元ファイルをバックアップ → 一時ファイルに XML で書き出して `plutil -lint` → 元ファイルと置き換え、の順に進める。
     lint に落ちたら元ファイルには触れない。ロード済みで無効化されていなければ bootout ＋ bootstrap で読み込み直し、
     未ロード・無効（`.plist.disabled` を含む）なら書き換えるだけにする
     */
    func save(_ schedule: Schedule, for job: MonitoredItem.LaunchdJob, now: Date = .now) async throws {
        let targetURL = job.plistURL.resolvingSymlinksInPath()
        let data = try Data(contentsOf: targetURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw PlistEditorError.unreadable(targetURL)
        }
        let output = try PropertyListSerialization.data(fromPropertyList: schedule.applyingTimers(to: plist), format: .xml, options: 0)

        try backUp(targetURL, label: job.label, now: now)
        try await replace(targetURL, with: output)
        try await reload(job)
    }

    private func backUp(_ url: URL, label: String, now: Date) throws {
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backupURL = backupDirectory.appending(path: "\(label)-\(Self.timestampFormatter.string(from: now)).plist")
        try fileManager.copyItem(at: url, to: backupURL)
    }

    /// 置き換えは同じボリュームの一時ディレクトリから `replaceItemAt` で行い、元ファイルの権限などの属性を引き継ぐ
    private func replace(_ url: URL, with data: Data) async throws {
        let temporaryDirectory = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        let temporaryURL = temporaryDirectory.appending(path: url.lastPathComponent)
        try data.write(to: temporaryURL)

        let lint = try await shell.run(Self.plutil, arguments: ["-lint", temporaryURL.path(percentEncoded: false)])
        guard lint.status == 0 else {
            throw PlistEditorError.lintFailed([lint.stdout, lint.stderr].joined().trimmingCharacters(in: .whitespacesAndNewlines))
        }
        _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
    }

    /// bootstrap にはリンク先ではなく LaunchAgents 内のパスを渡し、launchd から見えるパスを変えない
    private func reload(_ job: MonitoredItem.LaunchdJob) async throws {
        guard
            !job.isDisabled,
            try await launchctl.print(label: job.label) != nil
        else {
            return
        }
        try await launchctl.bootout(label: job.label)
        try await launchctl.bootstrap(plistURL: job.plistURL)
    }
}
