import Foundation

protocol StorageScanning: Sendable {
    func scan(previous: StorageScan?) async -> StorageScan
}

/**
 `du` で膨らみやすい場所を測る。ファイルの多い場所（uv などの `~/.cache`、DerivedData）は1つで数十秒〜2分かかり、
 1つずつ測ると全体で4分ほどかかった。`maxConcurrentCount` 本まで並べて、一番遅い場所の分で終わるようにする（全部を一度に走らせて Mac を重くしない）。
 読めないフォルダがあっても `du` は読めた分の合計を出すので、終了コードは見ない
 */
struct DiskUsage: StorageScanning {
    /// node_modules を探すときに入らないフォルダ。許可のダイアログが出る場所と、中に node_modules を置かない場所
    static let excludedFolders = ["Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public", "Applications"]
    /// プロジェクトはふつうホームから数段下に置くので、それより深くは探さない
    static let nodeModulesSearchDepth = 6
    static let maxConcurrentCount = 4

    private let shell: any ShellRunning
    private let home: URL
    private let now: @Sendable () -> Date

    init(
        shell: any ShellRunning = ShellRunner(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.shell = shell
        self.home = home
        self.now = now
    }

    func scan(previous: StorageScan?) async -> StorageScan {
        let locations = await withTaskGroup(of: StorageScan.Location?.self) { group in
            var pending = StorageLocation.allCases.makeIterator()
            for _ in 0..<Self.maxConcurrentCount {
                guard let location = pending.next() else { break }
                group.addTask { await measure(location, previous: previous) }
            }
            var locations = [StorageScan.Location]()
            for await location in group {
                if let location {
                    locations.append(location)
                }
                if let next = pending.next() {
                    group.addTask { await measure(next, previous: previous) }
                }
            }
            return locations
        }
        return StorageScan(date: now(), previousDate: previous?.date, locations: locations.sorted { $0.bytes > $1.bytes })
    }

    /**
     測れなかった場所（`du` の時間切れなど）は、0 として一覧から消すと次の走査で増えた分も出せなくなるので、前回の結果をそのまま残す。
     大きさが 0 の場所（使っていないツール）は出さない
     */
    private func measure(_ location: StorageLocation, previous: StorageScan?) async -> StorageScan.Location? {
        let previousLocation = previous?.locations.first { $0.location == location }
        guard let bytes = await totalBytes(of: await paths(of: location)) else {
            return previousLocation
        }
        guard bytes > 0 else {
            return nil
        }
        return StorageScan.Location(
            location: location,
            path: home.appending(path: location.revealRelativePath).path(percentEncoded: false),
            bytes: bytes,
            previousBytes: previousLocation?.bytes
        )
    }

    private func paths(of location: StorageLocation) async -> [String] {
        if location == .nodeModules {
            await nodeModulesPaths()
        } else {
            location.relativePaths
                .map { home.appending(path: $0).path(percentEncoded: false) }
                .filter { FileManager.default.fileExists(atPath: $0) }
        }
    }

    /// node_modules の中の node_modules は外側に含まれるので、見つけたらその中には入らない
    private func nodeModulesPaths() async -> [String] {
        let homePath = home.path(percentEncoded: false).trimmingSuffix("/")
        let excluded = Self.excludedFolders.flatMap { ["-path", "\(homePath)/\($0)", "-o"] }
        let arguments = [homePath, "-maxdepth", String(Self.nodeModulesSearchDepth), "("]
            + excluded
            + ["-name", ".*", ")", "-prune", "-o", "-type", "d", "-name", "node_modules", "-print", "-prune"]
        let output = try? await shell.run("/usr/bin/find", arguments: arguments, timeout: .seconds(120))
        return output?.stdout.split(whereSeparator: \.isNewline).map(String.init) ?? []
    }

    /// 測れなかったら nil。無い場所（パスが空）は 0
    private func totalBytes(of paths: [String]) async -> Int64? {
        guard !paths.isEmpty else {
            return 0
        }
        let output = try? await shell.run("/usr/bin/du", arguments: ["-skx"] + paths, timeout: .seconds(300))
        return output.map { Self.parseTotalBytes($0.stdout) }
    }

    /// `du -sk` の各行（`1234\t/path`）の大きさを足す。単位はキロバイト
    static func parseTotalBytes(_ text: String) -> Int64 {
        text.split(whereSeparator: \.isNewline).reduce(0) { total, line in
            let kilobytes = line.split(separator: "\t", maxSplits: 1).first.flatMap { Int64($0) } ?? 0
            return total + kilobytes * 1024
        }
    }
}
