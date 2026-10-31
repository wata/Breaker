import Foundation
import Testing
@testable import Breaker

struct ItemDescriptionReaderTests {
    @Test(arguments: [
        (
            "#!/bin/bash\n# 証明書の見張り: macOS アップデートで cert.pem が戻っていないか確かめる\nif grep -q x; then\n",
            "証明書の見張り: macOS アップデートで cert.pem が戻っていないか確かめる"
        ),
        ("#!/usr/bin/env bash\n# 値下がりを調べる。毎日8:00に実行される\n# 2行目\n", "値下がりを調べる。"),
        ("#!/usr/bin/env bash\n# Sync the calendar. Runs every 30 minutes.\n", "Sync the calendar."),
        // 1文目が改行で終わるなら、次の行には続けない
        ("#!/bin/sh\n# Daily Report → Slack\n# 続きの説明\n", "Daily Report → Slack"),
        ("#!/usr/bin/python3\n\"\"\"家の端末にダッシュボードを配信するサーバー。launchd で常駐。\n\n詳細\n\"\"\"\n", "家の端末にダッシュボードを配信するサーバー。"),
        ("#!/usr/bin/python3\n\"\"\"\nチームの予定の自動同期。launchd から起動される。\n\"\"\"\n", "チームの予定の自動同期。"),
        ("#!/usr/bin/python3\n\"\"\"一行だけの docstring\"\"\"\nimport os\n", "一行だけの docstring"),
        ("#!/bin/bash\n# check.sh\n#\n# 証明書を確認する\n", "証明書を確認する"),
        ("#!/bin/bash\n# <xbar.title>Speed</xbar.title>\n# <xbar.desc>回線速度を測る</xbar.desc>\n", "回線速度を測る"),
        ("echo hi\n# <swiftbar.desc>シバンがなくてもメタデータは読む</swiftbar.desc>\n", "シバンがなくてもメタデータは読む"),
    ] as [(String, String?)])
    func readsHeader(script: String, expected: String?) {
        #expect(ItemDescriptionReader.headerDescription(ofScript: script) == expected)
    }

    @Test(arguments: [
        // シバンがない先頭コメントは用途の説明とは限らない
        "# Alfred の Workflow では PATH を通す処理が必要\nexport PATH=/usr/local/bin:$PATH\n",
        // シバンの直後がコメントでない
        "#!/usr/bin/env bash\nset -euo pipefail\n# あとのコメント\n",
        "#!/usr/bin/env bash\n\nCOMMAND=fast-speedtest\n",
        "#!/usr/bin/env bash\n# launchd から定期実行するためのラッパー。\n# PATH を通して実行する\n",
        "#!/bin/bash\n# auto-fix-launcher.sh\n# Thin shell launcher for launchd to run Claude auto-fix.\n",
        "#!/bin/bash\n# A WRAPPER for the real tool\n",
        "",
    ])
    func noHeader(script: String) {
        #expect(ItemDescriptionReader.headerDescription(ofScript: script) == nil)
    }

    @Test(arguments: [
        ("# Planner\n\nThe shared calendar\n\n## Tech Stack\n", "Planner: The shared calendar"),
        (
            "# ニュース収集ツール\n\n記事を定期取得して蓄積するツール。設定は下を参照。\n\n- Node v22\n",
            "ニュース収集ツール: 記事を定期取得して蓄積するツール。"
        ),
        // 折り返した段落は1文につなげる
        ("# Tool\n\nFetches the feed\nand stores it. Then exits.\n", "Tool: Fetches the feed and stores it."),
        // 表・リスト・コード・バッジは段落ではないので、その先の段落を使う
        ("# Tool\n[![CI](badge.svg)](ci)\n\n| a | b |\n| - | - |\n\n- item\n1. step\n\n```bash\nnpm install\n```\n\nThe real summary.\n", "Tool: The real summary."),
        ("<!-- note -->\n# Title\n\nSummary\n", "Title: Summary"),
    ] as [(String, String?)])
    func summarizesReadme(readme: String, expected: String?) {
        #expect(ItemDescriptionReader.summary(ofReadme: readme) == expected)
    }

    @Test(arguments: [
        "# Scripts\n\n## cleanup-worktree.sh\n\nTears down a worktree.\n",
        "# App\n\n## テストアカウント\n\nUID | Name\n",
        "# Only List\n\n- a\n- b\n",
        "No heading here.\n",
        "",
    ])
    func noReadmeSummary(readme: String) {
        #expect(ItemDescriptionReader.summary(ofReadme: readme) == nil)
    }

    @Test func prefersHeaderOverReadme() throws {
        let home = try TemporaryDirectory()
        let project = home.url.appending(path: "dev/project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project.appending(path: ".git"), withIntermediateDirectories: true)
        try write("# Project\n\nThe project summary.\n", to: project.appending(path: "README.md"))
        let script = project.appending(path: "run.sh")
        try write("#!/bin/bash\n# ヘッダーの説明\n", to: script)

        #expect(ItemDescriptionReader.description(forScriptAt: script, home: home.url) == "ヘッダーの説明")
    }

    /// サブディレクトリの README に紹介文がなければ、さらに上の README を使う
    @Test func fallsBackToNearestReadmeWithSummary() throws {
        let home = try TemporaryDirectory()
        let project = home.url.appending(path: "dev/planner", directoryHint: .isDirectory)
        let scripts = project.appending(path: "scripts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appending(path: ".git"), withIntermediateDirectories: true)
        try write("# Planner\n\nThe shared calendar\n", to: project.appending(path: "README.md"))
        try write("# Scripts\n\n## cleanup-worktree.sh\n\nTears down a worktree.\n", to: scripts.appending(path: "README.md"))
        let script = scripts.appending(path: "auto-fix-launcher.sh")
        try write("#!/bin/bash\n# auto-fix-launcher.sh\n# Thin shell launcher for launchd.\n", to: script)

        #expect(ItemDescriptionReader.description(forScriptAt: script, home: home.url) == "Planner: The shared calendar")
    }

    @Test func stopsAtGitRoot() throws {
        let home = try TemporaryDirectory()
        let outer = home.url.appending(path: "dev", directoryHint: .isDirectory)
        let repository = outer.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository.appending(path: ".git"), withIntermediateDirectories: true)
        try write("# Outer\n\nUnrelated project.\n", to: outer.appending(path: "README.md"))
        let script = repository.appending(path: "run.sh")
        try write("#!/bin/bash\nset -e\n", to: script)

        #expect(ItemDescriptionReader.description(forScriptAt: script, home: home.url) == nil)
    }

    @Test func stopsAtHome() throws {
        let home = try TemporaryDirectory()
        let directory = home.url.appending(path: "Library/Scripts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write("# Home\n\nNot about any script.\n", to: home.url.appending(path: "README.md"))
        let script = directory.appending(path: "check.sh")
        try write("#!/bin/bash\nset -e\n", to: script)

        #expect(ItemDescriptionReader.description(forScriptAt: script, home: home.url) == nil)
    }

    @Test func missingScriptStillUsesReadme() throws {
        let home = try TemporaryDirectory()
        let project = home.url.appending(path: "dev/tool", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project.appending(path: ".git"), withIntermediateDirectories: true)
        try write("# Tool\n\nDoes the thing.\n", to: project.appending(path: "README.md"))

        #expect(ItemDescriptionReader.description(forScriptAt: project.appending(path: "missing.sh"), home: home.url) == "Tool: Does the thing.")
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}
