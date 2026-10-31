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

    private func performer(_ workspace: StubWorkspace) -> ItemActionPerformer {
        ItemActionPerformer(jobActions: JobActions(launchctl: LaunchctlService(shell: StubShell(output: .init(status: 0, stdout: "", stderr: "")))), workspace: workspace)
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
