import Foundation

/// 詳細ペインのボタンとサイドバーの右クリックメニューで同じ一覧を使う
struct ItemAction: Identifiable, Hashable, Sendable {
    enum Operation: Hashable, Sendable {
        case job(JobActions.Command, MonitoredItem.LaunchdJob)
        case open(URL)
        /// 実行権限付きの拡張子なしスクリプトを `open` すると Terminal で実行されてしまうので、テキストとして開く
        case openAsText(URL)
        case reveal(URL)
        case launchApp(URL)
        /// シートを開くだけ。保存は `AppModel.saveSchedule` が行い、そこで一覧を取り直す
        case editSchedule(MonitoredItem.LaunchdJob)
        /// その種類ではできない操作。ツールバーのボタンの組をそろえて無効で見せるためだけに使い、押せない
        case unavailable

        /// 開く・表示するだけの操作では項目の状態が変わらないので、一覧を取り直さない
        var changesState: Bool {
            switch self {
            case .job, .launchApp:
                true

            case .open, .openAsText, .reveal, .editSchedule, .unavailable:
                false
            }
        }
    }

    let title: String
    let systemImage: String
    let operation: Operation
    var isEnabled = true

    /// 1項目の中ではタイトルが重ならないように作っている
    var id: String {
        title
    }

    /// launchd ジョブ以外を選んでいるときにメニューバーの「項目」で無効で見せる組。`LaunchdJob.controlActions` と `reloadAction` に名前と絵を合わせる
    static var unavailableJobActions: [ItemAction] {
        [
            ItemAction(title: runNowTitle, systemImage: "play.fill", operation: .unavailable, isEnabled: false),
            ItemAction(title: stopTitle, systemImage: "pause.circle", operation: .unavailable, isEnabled: false),
            ItemAction(title: reloadTitle, systemImage: "arrow.clockwise", operation: .unavailable, isEnabled: false),
        ]
    }
}

extension ItemAction {
    /// 同じ操作を種類ごとの組や無効で見せる組でも作るので、名前と訳の注記を1か所にまとめる
    static var runNowTitle: String {
        String(localized: "Run Now", comment: "Action that runs a launchd job immediately")
    }

    static var stopTitle: String {
        String(localized: "Stop", comment: "Action that disables a launchd job so it stays stopped after logging in again")
    }

    static var reloadTitle: String {
        String(localized: "Reload", comment: "Action that loads an unloaded launchd job back into launchd")
    }

    static var launchTitle: String {
        String(localized: "Launch", comment: "Action that opens a monitored app that isn't running")
    }

    static var showInFinderTitle: String {
        String(localized: "Show in Finder", comment: "Action that reveals a file in Finder")
    }
}

enum ItemActionError: LocalizedError, Equatable {
    case destinationExists(URL)
    case fileNotFound(URL)
    case cannotOpen(URL)
    case textEditorNotFound

    var errorDescription: String? {
        switch self {
        case .destinationExists(let url):
            String(localized: "Can't rename because \(url.path(percentEncoded: false).abbreviatingHome) already exists")

        case .fileNotFound(let url):
            String(localized: "Can't find \(url.path(percentEncoded: false).abbreviatingHome)")

        case .cannotOpen(let url):
            String(localized: "Couldn't open \(url.path(percentEncoded: false).abbreviatingHome)")

        case .textEditorNotFound:
            String(localized: "Can't find an app to open text files")
        }
    }
}

extension MonitoredItem {
    /**
     項目の状態を変える操作のうち、ツールバーにボタンで並べるもの。状態で組を変えず、状態上できないものは消さずに無効にして、
     何ができるかを見せる
     */
    var controlActions: [ItemAction] {
        switch detail {
        case .launchdJob(let job):
            job.controlActions

        case .cronJob:
            // Breaker は crontab を書き換えないので、launchd と同じ組を無効で見せ、できないことを伝える
            [
                ItemAction(title: ItemAction.runNowTitle, systemImage: "play.fill", operation: .unavailable, isEnabled: false),
                ItemAction(title: ItemAction.stopTitle, systemImage: "pause.circle", operation: .unavailable, isEnabled: false),
            ]

        case .monitoredApp(let app):
            // launchd の今すぐ実行と同じ塗りの三角にそろえる
            [ItemAction(title: ItemAction.launchTitle, systemImage: "play.fill", operation: .launchApp(app.appURL), isEnabled: !app.isRunning)]

        case .folderAction, .swiftBarPlugin, .sourceFailure:
            []
        }
    }

    /// 状態を変える操作のうち、使う場面が限られるのでツールバーではメニューに入れるもの
    var secondaryControlActions: [ItemAction] {
        if case .launchdJob(let job) = detail {
            [job.reloadAction]
        } else {
            []
        }
    }

    /// メニューバーの「項目」に並べる、launchd ジョブの状態を変える操作。launchd ジョブでなければ nil
    var launchdJobActions: [ItemAction]? {
        if case .launchdJob(let job) = detail {
            job.controlActions + [job.reloadAction]
        } else {
            nil
        }
    }

    /**
     詳細の概要で原因の下に出す、今の状態から戻すための操作。1つだけに絞り、ツールバーやメニューにある操作と同じ処理を状態に合わせて選ぶ。
     走り直せば済む失敗は再実行、ファイルが無いときは直す先の定義ファイル、ログのエラーはそのログを見せる。
     正常・実行中のように戻すものがないとき、閲覧のみのジョブは nil
     */
    var recoveryAction: ItemAction? {
        switch detail {
        case .launchdJob(let job):
            guard job.origin.isManageable else {
                return nil
            }
            if job.isDisabled {
                return ItemAction(
                    title: String(localized: "Enable", comment: "Recovery action that re-enables a disabled launchd job"),
                    systemImage: "play.circle",
                    operation: .job(.resume, job)
                )
            }
            if job.service == nil {
                return job.reloadAction
            }
            guard case .failed(let reason, _) = status else {
                return nil
            }
            if reason == HealthCheck.logErrorReason {
                return job.errorLog.map(\.openAction)
            }
            if HealthCheck.isFileProblem(reason) {
                return job.revealPlistAction
            }
            return ItemAction(title: String(localized: "Run Again"), systemImage: "play.fill", operation: .job(.runNow, job))

        case .cronJob(let job):
            // crontab は Breaker からは直せず走らせることもできないので、ログを見せるだけ
            if
                case .failed(let reason, _) = status,
                reason == HealthCheck.logErrorReason
            {
                return job.errorLog.map(\.openAction)
            }
            return nil

        case .monitoredApp(let app):
            if !app.isRunning {
                return ItemAction(title: ItemAction.launchTitle, systemImage: "play.fill", operation: .launchApp(app.appURL))
            }
            // 起動中で要確認なのは /Applications の外から動いているときだけ。どこにあるかを見せる
            if case .warning = status {
                return ItemAction(title: ItemAction.showInFinderTitle, systemImage: "magnifyingglass", operation: .reveal(app.appURL))
            }
            return nil

        case .folderAction, .swiftBarPlugin, .sourceFailure:
            return nil
        }
    }

    /**
     設定を書き換える操作。止めているジョブ（`.plist.disabled` を含む）も、再開前に直せるよう出す。
     `/Library` のジョブは書き換えに管理者権限が要るので、cron と同じく出さない
     */
    var editActions: [ItemAction] {
        if
            case .launchdJob(let job) = detail,
            job.origin.isManageable
        {
            [ItemAction(title: String(localized: "Edit Schedule…"), systemImage: "calendar.badge.clock", operation: .editSchedule(job))]
        } else {
            []
        }
    }

    /// 関連ファイルを開く・Finder で表示する操作。見つからないスクリプトは出さない
    func fileActions(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [ItemAction] {
        switch detail {
        case .launchdJob(let job):
            job.fileActions(home: home, fileManager: fileManager)

        case .cronJob(let job):
            job.fileActions(fileManager: fileManager)

        case .folderAction(let action):
            [ItemAction(title: String(localized: "Open Folder"), systemImage: "folder", operation: .open(action.folderURL))]
                + action.scriptURLs(home: home, fileManager: fileManager).map { url in
                    ItemAction(title: String(localized: "Show \(url.lastPathComponent) in Finder"), systemImage: "magnifyingglass", operation: .reveal(url))
                }

        case .swiftBarPlugin(let plugin):
            [ItemAction(title: ItemAction.showInFinderTitle, systemImage: "magnifyingglass", operation: .reveal(plugin.fileURL))]

        case .monitoredApp(let app):
            [ItemAction(title: ItemAction.showInFinderTitle, systemImage: "magnifyingglass", operation: .reveal(app.appURL))]

        case .sourceFailure:
            []
        }
    }
}

extension MonitoredItem.LaunchdJob {
    var isDisabled: Bool {
        isDisabledFile || isDisabledLabel
    }

    /**
     今すぐ実行はロード済みで動いていないときだけ。停止と再開は同時に選べないので、無効化されているかで入れ替わる1つの操作にする。
     未ロードでも無効化されていなければ、停止（無効化）を選べる。
     停止は実行中の処理を止めるのではなく、無効にしてスケジュールを休ませる操作なので、stop ではなく一時停止の絵にし、再開を対の
     `play.circle` にする。今すぐ実行は再開と並んでも見分けられるよう、丸のない塗りの三角にする。
     `/Library` のジョブは管理者権限が要るので、同じ組を無効で見せる
     */
    var controlActions: [ItemAction] {
        let runNow = ItemAction(
            title: ItemAction.runNowTitle,
            systemImage: "play.fill",
            operation: .job(.runNow, self),
            isEnabled: origin.isManageable && service.map { !$0.isRunning } == true && !isDisabled
        )
        let toggle = isDisabled
            ? ItemAction(
                title: String(localized: "Resume", comment: "Action that re-enables a stopped launchd job"),
                systemImage: "play.circle",
                operation: .job(.resume, self),
                isEnabled: origin.isManageable
            )
            : ItemAction(title: ItemAction.stopTitle, systemImage: "pause.circle", operation: .job(.stop, self), isEnabled: origin.isManageable)
        return [runNow, toggle]
    }

    /**
     読み込まれていないときだけ。無効化されているなら、再開が読み込みまで行う。
     LaunchAgents にあればログイン時に読み込まれるはずのジョブを launchd に戻す操作なので、概要の復旧ボタンでも同じ名前で呼ぶ
     */
    var reloadAction: ItemAction {
        ItemAction(
            title: ItemAction.reloadTitle,
            systemImage: "arrow.clockwise",
            operation: .job(.reload, self),
            isEnabled: origin.isManageable && service == nil && !isDisabled
        )
    }

    func fileActions(home: URL, fileManager: FileManager) -> [ItemAction] {
        let logs = logFiles.map(\.openAction)
        let script = scriptURL(home: home, fileManager: fileManager).map {
            ItemAction(title: String(localized: "Open Script"), systemImage: "chevron.left.forwardslash.chevron.right", operation: .openAsText($0))
        }
        let destination = plistDestinationURL.map {
            ItemAction(title: String(localized: "Show Linked plist in Finder"), systemImage: "arrowshape.turn.up.right", operation: .reveal($0))
        }
        return logs
            + [script].compactMap { $0 }
            + [
                ItemAction(title: String(localized: "Open plist"), systemImage: "doc", operation: .openAsText(plistURL)),
                revealPlistAction,
            ]
            + [destination].compactMap { $0 }
    }

    var revealPlistAction: ItemAction {
        ItemAction(title: String(localized: "Show plist in Finder"), systemImage: "magnifyingglass", operation: .reveal(plistURL))
    }

    /// 実行コマンドのうち、ホーム配下にある最初のファイル。`python3 script.py` ならインタプリタではなく script.py を指す
    func scriptURL(home: URL, fileManager: FileManager) -> URL? {
        let homePath = home.path(percentEncoded: false)
        return programArguments
            .lazy
            .map { $0.expandingTilde(home: home) }
            .first { path in
                var isDirectory: ObjCBool = false
                return path.isPath(under: homePath)
                    && fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
            .map { URL(filePath: $0) }
    }
}

extension MonitoredItem.CronJob {
    /// ログとスクリプトを開く・Finder で表示するだけ。crontab そのものは `crontab -l` でしか読めないので出さない
    func fileActions(fileManager: FileManager) -> [ItemAction] {
        let logs = logFiles.flatMap { log in
            [
                log.openAction,
                ItemAction(title: log.revealActionTitle, systemImage: "magnifyingglass", operation: .reveal(URL(filePath: log.path))),
            ]
        }
        let script = scriptURL(fileManager: fileManager).map { url in
            [
                ItemAction(title: String(localized: "Open Script"), systemImage: "chevron.left.forwardslash.chevron.right", operation: .openAsText(url)),
                ItemAction(title: String(localized: "Show Script in Finder"), systemImage: "magnifyingglass", operation: .reveal(url)),
            ]
        } ?? []
        return logs + script
    }
}

extension MonitoredItem.LogFile {
    /// ツールバーのファイルの操作と、ログのエラーのときの概要の復旧ボタンで同じものを使う
    var openAction: ItemAction {
        ItemAction(title: openActionTitle, systemImage: "doc.text", operation: .open(URL(filePath: path)))
    }
}

extension MonitoredItem.FolderAction {
    /// System Events はスクリプト名しか返さないので、フォルダアクション用スクリプトの置き場所から探す
    func scriptURLs(home: URL, fileManager: FileManager) -> [URL] {
        scriptNames.compactMap { scriptURL(named: $0, home: home, fileManager: fileManager) }
    }

    /// どの置き場所にも無いスクリプト。消したり名前を変えたりしても、System Events は名前を返し続ける
    func missingScriptNames(home: URL, fileManager: FileManager) -> [String] {
        scriptNames.filter { scriptURL(named: $0, home: home, fileManager: fileManager) == nil }
    }

    /// AppleScript は Folder Action Scripts に、Automator で作ったフォルダアクション（.workflow）は Workflows に置かれる
    private func scriptURL(named name: String, home: URL, fileManager: FileManager) -> URL? {
        [
            home.appending(path: "Library/Scripts/Folder Action Scripts", directoryHint: .isDirectory),
            URL(filePath: "/Library/Scripts/Folder Action Scripts", directoryHint: .isDirectory),
            home.appending(path: "Library/Workflows/Applications/Folder Actions", directoryHint: .isDirectory),
        ]
        .map { $0.appending(path: name) }
        .first { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
}
