import Foundation

struct FolderActionError: LocalizedError {
    let status: Int32
    let message: String

    var errorDescription: String? {
        String(localized: "Couldn't get folder actions from System Events (exit code \(status)): \(message)")
    }
}

/// System Events のフォルダアクション。初回はオートメーションの許可ダイアログが出る
struct FolderActionSource: ItemSource {
    let kind = MonitoredItem.Kind.folderAction

    /**
     AppleScript のリスト表記を解析しなくて済むよう、1行目に全体の有効フラグ、
     2行目以降に1アクション1行で「名前 TAB パス TAB 有効 TAB スクリプト名…」を出す
     */
    private static let script = """
        tell application "System Events"
            set AppleScript's text item delimiters to tab
            set output to (folder actions enabled as text) & linefeed
            repeat with folderAction in folder actions
                set fields to {name of folderAction, path of folderAction, enabled of folderAction as text} & (name of every script of folderAction)
                set output to output & (fields as text) & linefeed
            end repeat
            return output
        end tell
        """

    private let shell: any ShellRunning
    private let homeDirectory: URL

    init(shell: any ShellRunning = ShellRunner(), homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.shell = shell
        self.homeDirectory = homeDirectory
    }

    func items() async throws -> [MonitoredItem] {
        let output = try await shell.run("/usr/bin/osascript", arguments: ["-e", Self.script])
        guard output.status == 0 else {
            throw FolderActionError(status: output.status, message: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let listing = Self.parse(output.stdout)
        return listing.actions.map { action in
            let folderExists = FileManager.default.fileExists(atPath: action.folderURL.path(percentEncoded: false))
            return MonitoredItem(
                key: action.folderURL.path(percentEncoded: false),
                name: action.name,
                status: Self.status(
                    of: action.detail,
                    isGloballyEnabled: listing.isEnabled,
                    folderExists: folderExists,
                    missingScripts: action.detail.missingScriptNames(home: homeDirectory, fileManager: .default)
                ),
                detail: .folderAction(action.detail)
            )
        }
    }
}

extension FolderActionSource {
    struct Listing: Equatable {
        /// システム全体のフォルダアクション機能のオン／オフ
        let isEnabled: Bool
        let actions: [Action]
    }

    struct Action: Equatable {
        let name: String
        let detail: MonitoredItem.FolderAction

        var folderURL: URL {
            detail.folderURL
        }
    }

    static func parse(_ output: String) -> Listing {
        let lines = output.split(separator: "\n")
        let actions = lines.dropFirst().compactMap { line -> Action? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else {
                return nil
            }
            return Action(
                name: fields[0],
                detail: MonitoredItem.FolderAction(
                    folderURL: URL(filePath: fields[1], directoryHint: .isDirectory),
                    scriptNames: fields.dropFirst(3).filter { !$0.isEmpty },
                    isEnabled: fields[2] == "true"
                )
            )
        }
        return Listing(isEnabled: lines.first == "true", actions: actions)
    }

    /// 詳細ペインでフォルダの行に印を付けるかを、この状態かどうかで決める
    static let missingFolderStatus = ItemStatus.warning(
        reason: String(localized: "Folder not found", comment: "Reason shown for a folder action whose folder doesn't exist"),
        note: String(localized: "it may not be mounted", comment: "Note in parentheses after Folder not found")
    )

    /**
     スクリプトが無ければフォルダにファイルが入っても動けないので失敗。
     対象フォルダが無いのは主にネットワークボリュームの未マウントで、その間はファイルも入らず取りこぼす仕事が無いので要確認にする
     */
    static func status(
        of action: MonitoredItem.FolderAction,
        isGloballyEnabled: Bool,
        folderExists: Bool,
        missingScripts: [String] = []
    ) -> ItemStatus {
        if !isGloballyEnabled {
            return .inactive(reason: String(localized: "Folder Actions are turned off"))
        }
        if !action.isEnabled {
            return .inactive(reason: String(localized: "Disabled", comment: "Status of a launchd job or folder action that is turned off"))
        }
        if !folderExists {
            return missingFolderStatus
        }
        if !missingScripts.isEmpty {
            return .failed(reason: String(localized: "Script not found"), note: missingScripts.joined(separator: ", "))
        }
        return .ok
    }
}
