import Foundation
import Testing
@testable import Breaker

struct FolderActionSourceTests {
    /// 実機で採取した出力。share1 はスクリプト名が空のまま返ってくる
    @Test func parsesRealOutput() throws {
        let listing = FolderActionSource.parse(try fixture("osascript-folder-actions"))
        #expect(listing.isEnabled)
        #expect(listing.actions.count == 2)

        let convert = listing.actions[0]
        #expect(convert.name == "Convert Videos")
        #expect(convert.folderURL.path(percentEncoded: false) == "/Users/me/Convert Videos/")
        #expect(convert.detail.scriptNames == ["Copy and Compress Videos.workflow"])
        #expect(convert.detail.isEnabled)

        let share = listing.actions[1]
        #expect(share.name == "share1")
        #expect(share.folderURL.path(percentEncoded: false) == "/Volumes/share1/")
        #expect(share.detail.scriptNames.isEmpty)
        #expect(share.detail.isEnabled)
    }

    @Test func parsesMultipleScriptsAndDisabledAction() {
        let listing = FolderActionSource.parse("false\nInbox\t/Users/me/Inbox\tfalse\ta.scpt\tb.workflow\n\n")
        #expect(!listing.isEnabled)
        #expect(listing.actions.first?.detail.scriptNames == ["a.scpt", "b.workflow"])
        #expect(listing.actions.first?.detail.isEnabled == false)
    }

    @Test(arguments: [
        (false, true, true, ItemStatus.inactive(reason: "Folder Actions are turned off")),
        (true, false, false, .inactive(reason: "Disabled")),
        (true, true, false, .warning(reason: "Folder not found", note: "it may not be mounted")),
        (true, true, true, .ok),
    ])
    func status(isGloballyEnabled: Bool, isEnabled: Bool, folderExists: Bool, expected: ItemStatus) {
        let action = MonitoredItem.FolderAction(folderURL: URL(filePath: "/Volumes/share1"), scriptNames: [], isEnabled: isEnabled)
        #expect(FolderActionSource.status(of: action, isGloballyEnabled: isGloballyEnabled, folderExists: folderExists) == expected)
    }

    /// スクリプトが無ければ動けないので失敗。フォルダが無い（未マウント）のは取りこぼす仕事が無いので要確認のまま
    @Test func missingScriptsFailAfterMissingFolder() {
        let action = MonitoredItem.FolderAction(folderURL: URL(filePath: "/Users/me/Inbox"), scriptNames: ["a.scpt", "b.scpt"], isEnabled: true)
        #expect(
            FolderActionSource.status(of: action, isGloballyEnabled: true, folderExists: true, missingScripts: ["a.scpt", "b.scpt"])
                == .failed(reason: "Script not found", note: "a.scpt, b.scpt")
        )
        #expect(
            FolderActionSource.status(of: action, isGloballyEnabled: true, folderExists: false, missingScripts: ["a.scpt"])
                == FolderActionSource.missingFolderStatus
        )
        #expect(FolderActionSource.status(of: action, isGloballyEnabled: false, folderExists: true, missingScripts: ["a.scpt"]).isInactive)
    }

    @Test func itemsCheckFolderExistence() async throws {
        let directory = try TemporaryDirectory()
        let existing = directory.url.path(percentEncoded: false)
        let scripts = directory.url.appending(path: "Library/Scripts/Folder Action Scripts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data().write(to: scripts.appending(path: "x.scpt"))
        let workflows = directory.url.appending(path: "Library/Workflows/Applications/Folder Actions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workflows.appending(path: "Compress.workflow"), withIntermediateDirectories: true)
        let output = "true\nHere\t\(existing)\ttrue\tx.scpt\nGone\t/Volumes/not-mounted-\(UUID())\ttrue\t\nRenamed\t\(existing)\ttrue\tx.scpt\tgone-\(UUID()).scpt\nAutomator\t\(existing)\ttrue\tCompress.workflow\n"
        let shell = StubShell(output: ShellOutput(status: 0, stdout: output, stderr: ""))
        let items = try await FolderActionSource(shell: shell, homeDirectory: directory.url).items()
        #expect(items.count == 4)
        #expect(items[0].status == .ok)
        // Automator のフォルダアクションは ~/Library/Workflows/Applications/Folder Actions にある
        #expect(items[3].status == .ok)
        #expect(items[1].status == .warning(reason: "Folder not found", note: "it may not be mounted"))
        #expect(items[1].status.fullReason == "Folder not found (it may not be mounted)")
        #expect(items[2].status.reason == "Script not found")
        #expect(items[2].status.note?.hasPrefix("gone-") == true)
        #expect(shell.calls.first?.executable == "/usr/bin/osascript")
    }

    @Test func throwsWhenOsascriptFails() async {
        let shell = StubShell(output: ShellOutput(status: 1, stdout: "", stderr: "execution error: Not authorized to send Apple events to System Events. (-1743)\n"))
        await #expect(throws: FolderActionError.self) {
            try await FolderActionSource(shell: shell).items()
        }
    }
}
