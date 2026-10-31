import Foundation

/// `launchctl print` から読み取った、ロード済みサービスの実行状態
struct LaunchdServiceInfo: Hashable, Sendable {
    enum LastExit: Hashable, Sendable {
        /// ロード後に一度も終了していない（KeepAlive で動き続けている、まだ起動していない）
        case never
        case code(Int32)
        case signal(Int32)

        var isFailure: Bool {
            self != .never && self != .code(0)
        }
    }

    /// `running` / `not running` など launchctl の表記そのまま
    let state: String
    let pid: Int32?
    let runs: Int
    let lastExit: LastExit

    var isRunning: Bool {
        state == "running"
    }
}

struct LaunchctlError: LocalizedError {
    let arguments: [String]
    let status: Int32
    let message: String

    var errorDescription: String? {
        String(localized: "launchctl \(arguments.joined(separator: " ")) failed with exit code \(status): \(message)")
    }
}

/**
 ログイン中ユーザーの GUI ドメイン（`gui/<uid>`）の launchd ジョブを扱う。
 `/Library/LaunchDaemons` のジョブは system ドメインにあり、状態を読むだけなので `print` と `disabledLabels` だけがドメインを選べる
 */
struct LaunchctlService: Sendable {
    enum Domain: Sendable {
        case gui
        case system
    }

    /// テストで実際に待たずに bootout 後の確認を回せるよう、待ち方を受け取る
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private static let executable = "/bin/launchctl"
    /// `launchctl print` でサービスが見つからないときの終了コード
    private static let notFoundStatus: Int32 = 113
    /// bootout 後に消えたかを確かめる間隔と回数（最大およそ5秒）
    private static let unloadPollInterval = Duration.milliseconds(100)
    private static let unloadPollLimit = 50

    private let shell: any ShellRunning
    private let uid: uid_t
    private let sleep: Sleep

    init(shell: any ShellRunning = ShellRunner(), uid: uid_t = getuid(), sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.shell = shell
        self.uid = uid
        self.sleep = sleep
    }

    /// 未ロード（見つからない）なら nil
    func print(label: String, in domain: Domain = .gui) async throws -> LaunchdServiceInfo? {
        let arguments = ["print", target(label, in: domain)]
        let output = try await shell.run(Self.executable, arguments: arguments)
        if output.status == Self.notFoundStatus {
            return nil
        }
        guard output.status == 0 else {
            throw LaunchctlError(arguments: arguments, status: output.status, message: output.stderr)
        }
        return Self.parsePrint(output.stdout)
    }

    /// `launchctl disable` 済みのラベル。enabled と明示されたものや一覧にないものは含まない
    func disabledLabels(in domain: Domain = .gui) async throws -> Set<String> {
        let output = try await runChecked(["print-disabled", name(of: domain)])
        return Self.parseDisabled(output.stdout)
    }

    func kickstart(label: String) async throws {
        try await runChecked(["kickstart", target(label)])
    }

    func enable(label: String) async throws {
        try await runChecked(["enable", target(label)])
    }

    func disable(label: String) async throws {
        try await runChecked(["disable", target(label)])
    }

    func bootstrap(plistURL: URL) async throws {
        try await runChecked(["bootstrap", name(of: .gui), plistURL.path(percentEncoded: false)])
    }

    /**
     bootout は launchd に取り外しを頼んだ時点で戻り、サービスはしばらく残る。その間に bootstrap すると
     「Bootstrap failed: 5: Input/output error」になるので、`print` で見つからなくなるまで待ってから戻る。
     待ちきれなくても失敗にはしない（取り外し自体は受け付けられている。続く bootstrap が失敗すればその理由を伝える）
     */
    func bootout(label: String) async throws {
        try await runChecked(["bootout", target(label)])
        for _ in 0..<Self.unloadPollLimit {
            guard try await print(label: label) != nil else { return }
            try await sleep(Self.unloadPollInterval)
        }
    }

    private func target(_ label: String, in domain: Domain = .gui) -> String {
        "\(name(of: domain))/\(label)"
    }

    private func name(of domain: Domain) -> String {
        switch domain {
        case .gui:
            "gui/\(uid)"

        case .system:
            "system"
        }
    }

    @discardableResult
    private func runChecked(_ arguments: [String]) async throws -> ShellOutput {
        let output = try await shell.run(Self.executable, arguments: arguments)
        guard output.status == 0 else {
            throw LaunchctlError(arguments: arguments, status: output.status, message: output.stderr)
        }
        return output
    }
}

extension LaunchctlService {
    /**
     サービスブロック直下のフィールドだけを読む。入れ子のブロック（coalition など）にも
     `state = active` のような同名の行があるので、波括弧の深さで区別する
     */
    static func parsePrint(_ output: String) -> LaunchdServiceInfo? {
        var fields = [String: String]()
        var depth = 0
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("{") {
                depth += 1
                continue
            }
            if trimmed == "}" {
                depth -= 1
                continue
            }
            guard
                depth == 1,
                let separator = trimmed.range(of: " = ")
            else {
                continue
            }
            fields[String(trimmed[..<separator.lowerBound])] = String(trimmed[separator.upperBound...])
        }
        guard let state = fields["state"] else {
            return nil
        }
        return LaunchdServiceInfo(
            state: state,
            pid: fields["pid"].flatMap { Int32($0) },
            runs: fields["runs"].flatMap { Int($0) } ?? 0,
            lastExit: parseLastExit(code: fields["last exit code"], signal: fields["last terminating signal"])
        )
    }

    /**
     実機で確認できた表記は `0` / `1` / `(never exited)`。
     `78: EX_CONFIG` のような説明付き、`Killed: 9` のようなシグナル終了、
     `launchctl list` と同じ負数でのシグナル表記は launchd の出力例からの推測で対応している
     */
    private static func parseLastExit(code: String?, signal: String?) -> LaunchdServiceInfo.LastExit {
        let signalNumber = signal?.split(separator: ":").last.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        if let signalNumber {
            return .signal(signalNumber)
        }
        guard
            let code,
            let number = code.split(separator: ":").first.flatMap({ Int32($0) })
        else {
            return .never
        }
        return number < 0 ? .signal(-number) : .code(number)
    }

    static func parseDisabled(_ output: String) -> Set<String> {
        let entry = /"(?<label>[^"]+)" => disabled/
        return Set(output.split(separator: "\n").compactMap { line in
            line.firstMatch(of: entry).map { String($0.label) }
        })
    }
}
