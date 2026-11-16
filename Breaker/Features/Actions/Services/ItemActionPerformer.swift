import AppKit
import UniformTypeIdentifiers

/// テストで Finder やエディタを実際に開かずに呼び出しを記録できるよう、`NSWorkspace` の使う部分だけを切り出す
@MainActor
protocol WorkspaceOpening {
    func open(_ url: URL) -> Bool
    func activateFileViewerSelecting(_ fileURLs: [URL])
    func openAsText(_ url: URL) async throws
}

extension NSWorkspace: WorkspaceOpening {
    func openAsText(_ url: URL) async throws {
        guard let editorURL = urlForApplication(toOpen: .plainText) else {
            throw ItemActionError.textEditorNotFound
        }
        try await open([url], withApplicationAt: editorURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// テストで利用者のクリップボードを書き換えずに中身を確かめられるよう、`NSPasteboard` の使う部分だけを切り出す
@MainActor
protocol PasteboardWriting {
    func write(_ text: String)
}

extension NSPasteboard: PasteboardWriting {
    func write(_ text: String) {
        clearContents()
        setString(text, forType: .string)
    }
}

@MainActor
struct ItemActionPerformer {
    private let jobActions: JobActions
    private let workspace: any WorkspaceOpening
    private let pasteboard: any PasteboardWriting
    private let fileManager: FileManager

    init(
        jobActions: JobActions = JobActions(),
        workspace: any WorkspaceOpening = NSWorkspace.shared,
        pasteboard: any PasteboardWriting = NSPasteboard.general,
        fileManager: FileManager = .default
    ) {
        self.jobActions = jobActions
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.fileManager = fileManager
    }

    func perform(_ operation: ItemAction.Operation) async throws {
        switch operation {
        case .job(let command, let job):
            try await jobActions.perform(command, on: job)

        case .open(let url):
            guard workspace.open(url) else {
                throw ItemActionError.cannotOpen(url)
            }

        case .openAsText(let url):
            try requireExistence(of: url)
            try await workspace.openAsText(url)

        case .reveal(let url):
            // 見つからないと Finder は何も言わずに無視するので、先に確かめて伝える
            try requireExistence(of: url)
            workspace.activateFileViewerSelecting([url])

        case .editSchedule:
            // シートを開く操作なので `AppModel.request` が受け取り、ここには来ない
            break

        case .copyPrompt(let item):
            pasteboard.write(await AIPrompt.make(for: item, fileManager: fileManager))

        case .unavailable:
            // 無効のボタンにしか付けないので、押されることはない
            break
        }
    }

    /// リンク切れのシンボリックリンクも Finder で選べるので、リンク自体があるかで判定する
    private func requireExistence(of url: URL) throws {
        guard (try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil else {
            throw ItemActionError.fileNotFound(url)
        }
    }
}
