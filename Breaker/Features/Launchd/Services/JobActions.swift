import Foundation

/**
 launchd ジョブの実行・停止・再開。停止は `disable` してから外すので、ログインし直しても読み込まれない。
 未ロードの bootout とロード済みの bootstrap は失敗するが、その終了コードは実機で確かめられていない
 （本物のジョブに対して試せない）。終了コードで「無害な失敗」を見分けて握りつぶす代わりに、
 どちらも直前に `print`（未ロードは 113 で確認済み）でロード状態を確かめてから呼ぶ。
 `FileManager` が Sendable でないので、リネームも含めてメインアクターで扱う（launchctl の待ちはメインを塞がない）
 */
@MainActor
struct JobActions {
    enum Command: Hashable, Sendable {
        case runNow
        case stop
        case resume
        case reload

        var needsConfirmation: Bool {
            self == .stop
        }
    }

    private let launchctl: LaunchctlService
    private let fileManager: FileManager

    init(launchctl: LaunchctlService = LaunchctlService(), fileManager: FileManager = .default) {
        self.launchctl = launchctl
        self.fileManager = fileManager
    }

    func perform(_ command: Command, on job: MonitoredItem.LaunchdJob) async throws {
        switch command {
        case .runNow:
            try await launchctl.kickstart(label: job.label)

        case .stop:
            try await launchctl.disable(label: job.label)
            if try await launchctl.print(label: job.label) != nil {
                try await launchctl.bootout(label: job.label)
            }

        case .resume:
            let plistURL = job.isDisabledFile ? try restore(job.plistURL) : job.plistURL
            try await launchctl.enable(label: job.label)
            try await bootstrapIfUnloaded(label: job.label, plistURL: plistURL)

        case .reload:
            try await bootstrapIfUnloaded(label: job.label, plistURL: job.plistURL)
        }
    }

    /**
     `name.plist.disabled` を `name.plist` に戻す。シンボリックリンクはリンク自体を改名し、リンク先には触れない。
     `fileExists` はリンクをたどるので、リンク切れの `name.plist` も見落とさないよう lstat 相当の `attributesOfItem` で調べる
     */
    func restore(_ url: URL) throws -> URL {
        let destination = url.deletingPathExtension()
        guard (try? fileManager.attributesOfItem(atPath: destination.path(percentEncoded: false))) == nil else {
            throw ItemActionError.destinationExists(destination)
        }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }

    private func bootstrapIfUnloaded(label: String, plistURL: URL) async throws {
        guard try await launchctl.print(label: label) == nil else { return }
        try await launchctl.bootstrap(plistURL: plistURL)
    }
}
