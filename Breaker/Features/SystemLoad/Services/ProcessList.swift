import Foundation

/// `ps` の1行
struct ProcessUsage: Hashable, Sendable {
    /// 1コアを使い切って 100。アクティビティモニタの「% CPU」と同じ値
    let cpuPercent: Double
    /// 実行ファイルのパス。パスを持たないプロセス（kernel_task など）は名前だけ
    let executable: String
}

protocol ProcessListReading: Sendable {
    func read() async throws -> [ProcessUsage]
}

/**
 全ユーザーのプロセスの CPU を `ps` で読む。root や別のユーザーのプロセス（kernel_task・WindowServer）は
 `proc_pid_rusage` では読めないが、`ps` なら読める。`%cpu` は直近の数秒をならした値なので、1分ごとに読めば足りる
 */
struct ProcessList: ProcessListReading {
    private let shell: any ShellRunning

    init(shell: any ShellRunning = ShellRunner()) {
        self.shell = shell
    }

    func read() async throws -> [ProcessUsage] {
        let output = try await shell.run("/bin/ps", arguments: ["-Ao", "pcpu=,comm="], timeout: .seconds(10))
        return Self.parse(output.stdout)
    }

    /// 実行ファイルのパスには空白が入る（`Google Chrome Helper`）ので、前の1列だけを区切り、残りをまるごとパスにする
    static func parse(_ text: String) -> [ProcessUsage] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard
                fields.count == 2,
                let cpu = Double(fields[0])
            else {
                return nil
            }
            return ProcessUsage(cpuPercent: cpu, executable: String(fields[1]))
        }
    }
}

extension ProcessUsage {
    /**
     この実行ファイルを含む一番外側の .app。Xcode のビルドの `swift-frontend` も Chrome の `Google Chrome Helper` も、
     アプリの中にあるので、そのアプリの負荷としてまとめる。アプリに入っていなければ nil
     */
    var bundlePath: String? {
        executable.range(of: ".app/").map { String(executable[..<$0.lowerBound]) + ".app" }
    }
}

extension SystemLoad.Consumer {
    /**
     プロセスをアプリごとにまとめ、使っている順に並べる。名前はアプリの表示名（`Xcode-27.2.0.app` でも「Xcode」）にし、
     読めなければ .app を除いたファイル名にする。アプリに入っていないプロセスは実行ファイルの名前でまとめる。
     記録と判定は名前で引くので、同じ名前のアプリ（Xcode の2つの版など）は1つにまとめ、名前が重ならないようにする
     */
    static func consumers(
        from processes: [ProcessUsage],
        bundleName: (String) -> String? = Self.bundleName
    ) -> [SystemLoad.Consumer] {
        var bundleNames = [String: String]()
        let groups = Dictionary(grouping: processes) { process in
            guard let bundlePath = process.bundlePath else {
                return URL(filePath: process.executable).lastPathComponent
            }
            let name = bundleNames[bundlePath] ?? bundleName(bundlePath) ?? URL(filePath: bundlePath).deletingPathExtension().lastPathComponent
            bundleNames[bundlePath] = name
            return name
        }
        return groups.map { name, processes in
            SystemLoad.Consumer(
                name: name,
                bundlePath: processes.lazy.compactMap(\.bundlePath).first,
                cpuPercent: processes.reduce(0) { $0 + $1.cpuPercent }
            )
        }
        .sorted { lhs, rhs in
            if lhs.cpuPercent == rhs.cpuPercent {
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            } else {
                lhs.cpuPercent > rhs.cpuPercent
            }
        }
    }

    static func bundleName(_ path: String) -> String? {
        let bundle = Bundle(path: path)
        let info = bundle?.localizedInfoDictionary ?? bundle?.infoDictionary
        return (info?["CFBundleDisplayName"] ?? info?["CFBundleName"]) as? String
    }
}
