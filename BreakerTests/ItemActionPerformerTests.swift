import Foundation
import Testing
@testable import Breaker

@MainActor
struct ItemActionPerformerTests {
    @Test func revealSelectsSymlinkItself() async throws {
        let directory = try TemporaryDirectory()
        let linkURL = directory.url.appending(path: "job.plist")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: directory.url.appending(path: "missing.plist"))
        let workspace = StubWorkspace()

        try await performer(workspace).perform(.reveal(linkURL))

        #expect(workspace.calls == ["reveal \(linkURL.path(percentEncoded: false))"])
    }

    @Test func revealMissingFileThrows() async throws {
        let directory = try TemporaryDirectory()
        let missingURL = directory.url.appending(path: "missing.log")
        let workspace = StubWorkspace()

        await #expect(throws: ItemActionError.fileNotFound(missingURL)) {
            try await performer(workspace).perform(.reveal(missingURL))
        }
        #expect(workspace.calls.isEmpty)
    }

    @Test func openFailureThrows() async {
        let workspace = StubWorkspace()
        workspace.opens = false
        let url = URL(filePath: "/tmp/job.log")

        await #expect(throws: ItemActionError.cannotOpen(url)) {
            try await performer(workspace).perform(.open(url))
        }
        #expect(workspace.calls == ["open /tmp/job.log"])
    }

    @Test func launchAppUsesWorkspace() async throws {
        let workspace = StubWorkspace()
        try await performer(workspace).perform(.launchApp(URL(filePath: "/Applications/Example.app")))
        #expect(workspace.calls == ["launch /Applications/Example.app"])
    }

    @Test func copyPromptWritesToPasteboard() async throws {
        let workspace = StubWorkspace()
        let pasteboard = StubPasteboard()
        let job = MonitoredItem.LaunchdJob.stub(programArguments: ["/usr/bin/false"])
        let item = MonitoredItem(key: job.label, name: job.label, status: .failed(reason: "Exit code 1"), detail: .launchdJob(job))

        try await performer(workspace, pasteboard: pasteboard).perform(.copyPrompt(item))

        #expect(pasteboard.texts.count == 1)
        #expect(pasteboard.texts.first?.hasPrefix("cd /tmp/LaunchAgents\n") == true)
        #expect(pasteboard.texts.first?.contains("Label: com.example.job") == true)
        #expect(workspace.calls.isEmpty)
    }

    private func performer(_ workspace: StubWorkspace, pasteboard: StubPasteboard = StubPasteboard()) -> ItemActionPerformer {
        ItemActionPerformer(
            jobActions: JobActions(launchctl: LaunchctlService(shell: StubShell(output: .init(status: 0, stdout: "", stderr: "")))),
            workspace: workspace,
            pasteboard: pasteboard
        )
    }
}

@MainActor
final class StubWorkspace: WorkspaceOpening {
    var opens = true
    private(set) var calls = [String]()

    func open(_ url: URL) -> Bool {
        calls.append("open \(url.path(percentEncoded: false))")
        return opens
    }

    func activateFileViewerSelecting(_ fileURLs: [URL]) {
        calls += fileURLs.map { "reveal \($0.path(percentEncoded: false))" }
    }

    func openAsText(_ url: URL) async throws {
        calls.append("openAsText \(url.path(percentEncoded: false))")
    }

    func openApplication(at url: URL) async throws {
        calls.append("launch \(url.path(percentEncoded: false))")
    }
}

@MainActor
final class StubPasteboard: PasteboardWriting {
    private(set) var texts = [String]()

    func write(_ text: String) {
        texts.append(text)
    }
}
