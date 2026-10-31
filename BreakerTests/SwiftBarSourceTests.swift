import Foundation
import Testing
@testable import Breaker

struct SwiftBarSourceTests {
    @Test(arguments: [
        ("connect.3s.sh", 3.0),
        ("speedtest.5m.sh", 300.0),
        ("weather.1h.py", 3600.0),
        ("backup.1d.sh", 86400.0),
        ("my.plugin.10m.rb", 600.0),
    ] as [(String, TimeInterval?)])
    func parsesRefreshInterval(fileName: String, expected: TimeInterval?) {
        #expect(SwiftBarSource.refreshInterval(fileName: fileName) == expected)
    }

    @Test(arguments: ["static.sh", "noextension", "bad.5x.sh", "m5.sh"])
    func noRefreshInterval(fileName: String) {
        #expect(SwiftBarSource.refreshInterval(fileName: fileName) == nil)
    }

    @Test func listsPluginFiles() async throws {
        let home = try TemporaryDirectory()
        let directory = home.url.appending(path: "SwiftBar", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "subdirectory"), withIntermediateDirectories: true)
        try Data().write(to: directory.appending(path: ".repository.json"))
        try Data().write(to: directory.appending(path: "connect.3s.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appending(path: "connect.3s.sh").path(percentEncoded: false))
        try Data().write(to: directory.appending(path: "readonly.5m.sh"))

        let shell = StubShell(output: ShellOutput(status: 0, stdout: "~/SwiftBar\n", stderr: ""))
        let source = SwiftBarSource(shell: shell, runningApps: { [RunningApp(bundleID: SwiftBarSource.bundleID, bundleURL: nil, name: "SwiftBar")] }, homeDirectory: home.url)
        let items = try await source.items().sorted { $0.name < $1.name }

        #expect(items.map(\.name) == ["connect.3s.sh", "readonly.5m.sh"])
        #expect(items.map(\.status) == [.ok, .failed(reason: "No permission to execute")])
        #expect(shell.calls.first?.arguments == ["read", "com.ameba.SwiftBar", "PluginDirectory"])
    }

    @Test(arguments: [
        (false, true, ItemStatus.warning(reason: "SwiftBar isn't running")),
        (true, false, .failed(reason: "No permission to execute")),
        (true, true, .ok),
    ])
    func status(isAppRunning: Bool, isExecutable: Bool, expected: ItemStatus) {
        #expect(SwiftBarSource.status(isAppRunning: isAppRunning, isExecutable: isExecutable) == expected)
    }

    @Test(arguments: [
        ("#!/bin/bash\necho", "/bin/bash"),
        ("#! /opt/homebrew/bin/python3 -u\nprint()", "/opt/homebrew/bin/python3"),
        // PATH を引かないと分からないので見ない
        ("#!/usr/bin/env python3\nprint()", nil),
        ("#!python3\n", nil),
        ("echo no shebang", nil),
    ] as [(String, String?)])
    func readsShebangInterpreter(script: String, expected: String?) {
        #expect(SwiftBarSource.interpreter(ofScript: script) == expected)
    }

    /// 実行できないプラグインは SwiftBar が動かせないので失敗。SwiftBar を終了しているのは起動すれば動くので要確認
    @Test func missingInterpreterFailsAfterPermission() {
        let problem = ItemStatus.failed(reason: "Interpreter not found", note: "/opt/homebrew/bin/python3")
        #expect(SwiftBarSource.status(isAppRunning: true, isExecutable: true, fileFailure: problem) == problem)
        #expect(SwiftBarSource.status(isAppRunning: true, isExecutable: false, fileFailure: problem) == .failed(reason: "No permission to execute"))
        #expect(SwiftBarSource.status(isAppRunning: false, isExecutable: false, fileFailure: problem) == .warning(reason: "SwiftBar isn't running"))
    }

    @Test func listsMissingInterpreter() async throws {
        let home = try TemporaryDirectory()
        let directory = home.url.appending(path: "SwiftBar", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plugin = directory.appending(path: "weather.1h.py")
        try Data("#!/nonexistent-\(UUID())/python3\nprint()\n".utf8).write(to: plugin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plugin.path(percentEncoded: false))

        let shell = StubShell(output: ShellOutput(status: 0, stdout: "~/SwiftBar\n", stderr: ""))
        let source = SwiftBarSource(shell: shell, runningApps: { [RunningApp(bundleID: SwiftBarSource.bundleID, bundleURL: nil, name: "SwiftBar")] }, homeDirectory: home.url)
        let status = try await source.items().first?.status
        #expect(status?.reason == "Interpreter not found")
        #expect(status?.note?.hasPrefix("/nonexistent-") == true)
    }

    /// SwiftBar を入れていない Mac。macOS によって stderr の文言が違う
    @Test(arguments: [
        "The domain/default pair of (com.ameba.SwiftBar, PluginDirectory) does not exist\n",
        "Error: Domain 'com.ameba.SwiftBar' not found.\n",
        "Error: Could not find key 'PluginDirectory' in domain 'com.ameba.SwiftBar'.\n",
    ])
    func listsNothingWhenPluginDirectoryIsNotSet(stderr: String) async throws {
        let shell = StubShell(output: ShellOutput(status: 1, stdout: "", stderr: stderr))
        let items = try await SwiftBarSource(shell: shell, runningApps: { [] }).items()
        #expect(items.isEmpty)
    }

    @Test func listsNothingWhenPluginDirectoryIsMissing() async throws {
        let home = try TemporaryDirectory()
        let shell = StubShell(output: ShellOutput(status: 0, stdout: "~/SwiftBar\n", stderr: ""))
        let items = try await SwiftBarSource(shell: shell, runningApps: { [] }, homeDirectory: home.url).items()
        #expect(items.isEmpty)
    }

    @Test func throwsOnOtherDefaultsError() async {
        let shell = StubShell(output: ShellOutput(status: 1, stdout: "", stderr: "Error: Operation not permitted\n"))
        await #expect(throws: SwiftBarError.self) {
            try await SwiftBarSource(shell: shell, runningApps: { [] }).items()
        }
    }
}
