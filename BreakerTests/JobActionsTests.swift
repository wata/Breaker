import Foundation
import Testing
@testable import Breaker

/// launchctl はすべてスタブで受け、実システムには一切送らない。リネームは一時ディレクトリの中だけで行う
@MainActor
struct JobActionsTests {
    @Test func runNowKickstarts() async throws {
        let shell = launchctlShell(isLoaded: true)
        try await JobActions(launchctl: LaunchctlService(shell: shell, uid: 501)).perform(.runNow, on: .stub())
        #expect(shell.arguments == [["kickstart", "gui/501/com.example.job"]])
    }

    @Test func stopDisablesThenBootsOutLoadedJob() async throws {
        let shell = launchctlShell(isLoaded: true)
        try await JobActions(launchctl: LaunchctlService(shell: shell, uid: 501)).perform(.stop, on: .stub())
        #expect(shell.arguments == [
            ["disable", "gui/501/com.example.job"],
            ["print", "gui/501/com.example.job"],
            ["bootout", "gui/501/com.example.job"],
            ["print", "gui/501/com.example.job"],
        ])
    }

    @Test func stopSkipsBootoutWhenAlreadyUnloaded() async throws {
        let shell = launchctlShell(isLoaded: false)
        try await JobActions(launchctl: LaunchctlService(shell: shell, uid: 501)).perform(.stop, on: .stub())
        #expect(shell.arguments == [
            ["disable", "gui/501/com.example.job"],
            ["print", "gui/501/com.example.job"],
        ])
    }

    @Test func resumeEnablesThenBootstrapsUnloadedJob() async throws {
        let shell = launchctlShell(isLoaded: false)
        let job = MonitoredItem.LaunchdJob.stub(isDisabledLabel: true)
        try await JobActions(launchctl: LaunchctlService(shell: shell, uid: 501)).perform(.resume, on: job)
        #expect(shell.arguments == [
            ["enable", "gui/501/com.example.job"],
            ["print", "gui/501/com.example.job"],
            ["bootstrap", "gui/501", "/tmp/LaunchAgents/com.example.job.plist"],
        ])
    }

    /// disable だけされてロードされたままのジョブは、bootstrap すると失敗するので enable だけにする
    @Test func resumeSkipsBootstrapWhenStillLoaded() async throws {
        let shell = launchctlShell(isLoaded: true)
        let job = MonitoredItem.LaunchdJob.stub(isDisabledLabel: true)
        try await JobActions(launchctl: LaunchctlService(shell: shell, uid: 501)).perform(.resume, on: job)
        #expect(shell.arguments == [
            ["enable", "gui/501/com.example.job"],
            ["print", "gui/501/com.example.job"],
        ])
    }

    @Test func reloadBootstrapsUnloadedJob() async throws {
        let shell = launchctlShell(isLoaded: false)
        try await JobActions(launchctl: LaunchctlService(shell: shell, uid: 501)).perform(.reload, on: .stub())
        #expect(shell.arguments == [
            ["print", "gui/501/com.example.job"],
            ["bootstrap", "gui/501", "/tmp/LaunchAgents/com.example.job.plist"],
        ])
    }

    @Test func resumeRenamesDisabledFileBeforeBootstrapping() async throws {
        let directory = try TemporaryDirectory()
        let disabledURL = directory.url.appending(path: "com.example.job.plist.disabled")
        try Data("plist".utf8).write(to: disabledURL)
        let shell = launchctlShell(isLoaded: false)
        let job = MonitoredItem.LaunchdJob.stub(plistURL: disabledURL, isDisabledFile: true)

        try await JobActions(launchctl: LaunchctlService(shell: shell, uid: 501)).perform(.resume, on: job)

        let plistURL = directory.url.appending(path: "com.example.job.plist")
        #expect(!FileManager.default.fileExists(atPath: disabledURL.path(percentEncoded: false)))
        #expect(try String(contentsOf: plistURL, encoding: .utf8) == "plist")
        #expect(shell.arguments == [
            ["enable", "gui/501/com.example.job"],
            ["print", "gui/501/com.example.job"],
            ["bootstrap", "gui/501", plistURL.path(percentEncoded: false)],
        ])
    }

    /// リンク先（リポジトリ内の plist）の名前は変えず、LaunchAgents のリンクだけを改名する
    @Test func restoreRenamesSymlinkItself() throws {
        let directory = try TemporaryDirectory()
        let targetURL = directory.url.appending(path: "repo-job.plist")
        try Data("plist".utf8).write(to: targetURL)
        let linkURL = directory.url.appending(path: "com.example.job.plist.disabled")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let restored = try JobActions().restore(linkURL)

        #expect(restored.lastPathComponent == "com.example.job.plist")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: restored.path(percentEncoded: false)) == targetURL.path(percentEncoded: false))
        #expect(FileManager.default.fileExists(atPath: targetURL.path(percentEncoded: false)))
        #expect((try? FileManager.default.attributesOfItem(atPath: linkURL.path(percentEncoded: false))) == nil)
    }

    @Test func resumeRefusesWhenPlistAlreadyExists() async throws {
        let directory = try TemporaryDirectory()
        let disabledURL = directory.url.appending(path: "com.example.job.plist.disabled")
        let plistURL = directory.url.appending(path: "com.example.job.plist")
        try Data("disabled".utf8).write(to: disabledURL)
        try Data("existing".utf8).write(to: plistURL)
        let shell = launchctlShell(isLoaded: false)
        let job = MonitoredItem.LaunchdJob.stub(plistURL: disabledURL, isDisabledFile: true)

        await #expect(throws: ItemActionError.destinationExists(plistURL)) {
            try await JobActions(launchctl: LaunchctlService(shell: shell, uid: 501)).perform(.resume, on: job)
        }
        #expect(shell.arguments.isEmpty)
        #expect(try String(contentsOf: disabledURL, encoding: .utf8) == "disabled")
        #expect(try String(contentsOf: plistURL, encoding: .utf8) == "existing")
    }

    /// `fileExists` はリンクをたどるので、リンク切れの `.plist` を「ない」と誤判定して上書きしないこと
    @Test func restoreRefusesWhenDanglingSymlinkExists() throws {
        let directory = try TemporaryDirectory()
        let disabledURL = directory.url.appending(path: "com.example.job.plist.disabled")
        try Data("disabled".utf8).write(to: disabledURL)
        let plistURL = directory.url.appending(path: "com.example.job.plist")
        try FileManager.default.createSymbolicLink(at: plistURL, withDestinationURL: directory.url.appending(path: "missing.plist"))

        #expect(throws: ItemActionError.destinationExists(plistURL)) {
            try JobActions().restore(disabledURL)
        }
        #expect(FileManager.default.fileExists(atPath: disabledURL.path(percentEncoded: false)))
    }

    @Test func launchctlFailureCarriesStderr() async throws {
        let shell = StubShell { call in
            call.arguments.first == "disable"
                ? ShellOutput(status: 1, stdout: "", stderr: "Operation not permitted")
                : ShellOutput(status: 0, stdout: "", stderr: "")
        }
        let error = await #expect(throws: LaunchctlError.self) {
            try await JobActions(launchctl: LaunchctlService(shell: shell, uid: 501)).perform(.stop, on: .stub())
        }
        #expect(error?.localizedDescription.contains("Operation not permitted") == true)
        // disable に失敗したら bootout まで進まない
        #expect(shell.arguments == [["disable", "gui/501/com.example.job"]])
    }

    private func launchctlShell(isLoaded: Bool) -> StubShell {
        .launchctl(isLoaded: isLoaded)
    }
}

extension StubShell {
    /// launchctl 以外が呼ばれていないことも確かめるため、実行ファイルを確認してから引数だけを並べる
    var arguments: [[String]] {
        calls.map { call in
            #expect(call.executable == "/bin/launchctl")
            return call.arguments
        }
    }
}

extension MonitoredItem.LaunchdJob {
    static func stub(
        plistURL: URL = URL(filePath: "/tmp/LaunchAgents/com.example.job.plist"),
        isDisabledFile: Bool = false,
        isDisabledLabel: Bool = false,
        programArguments: [String] = [],
        standardOutPath: String? = nil,
        standardErrorPath: String? = nil,
        service: LaunchdServiceInfo? = nil,
        origin: Origin = .userAgent
    ) -> Self {
        Self(
            label: "com.example.job",
            origin: origin,
            plistURL: plistURL,
            isDisabledFile: isDisabledFile,
            isDisabledLabel: isDisabledLabel,
            isHomeJob: origin == .userAgent,
            programArguments: programArguments,
            schedule: Schedule(),
            standardOutPath: standardOutPath,
            standardErrorPath: standardErrorPath,
            environmentVariables: [],
            service: service,
            lastRun: nil
        )
    }
}
