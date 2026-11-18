import Foundation

/// その時点の Mac 全体の値。テストで差し替えられるよう、読み方をまとめて受け取る
struct SystemReadings: Hashable, Sendable {
    let coreCount: Int
    let loadAverage: Double
    let thermalState: SystemLoad.ThermalState
    let memoryPressure: SystemLoad.MemoryPressure

    static func read() -> SystemReadings {
        var loads = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loads, 3)
        return SystemReadings(
            coreCount: ProcessInfo.processInfo.activeProcessorCount,
            loadAverage: loadCount > 0 ? loads[0] : 0,
            thermalState: SystemLoad.ThermalState(ProcessInfo.processInfo.thermalState),
            memoryPressure: SystemLoad.MemoryPressure(level: memoryPressureLevel())
        )
    }

    /// 読めなければ 1（正常）として扱う
    private static func memoryPressureLevel() -> Int32 {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? level : 1
    }
}

extension SystemLoad.ThermalState {
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:
            self = .nominal

        case .fair:
            self = .fair

        case .serious:
            self = .serious

        case .critical:
            self = .critical

        @unknown default:
            self = .nominal
        }
    }
}

extension SystemLoad.MemoryPressure {
    /// `kern.memorystatus_vm_pressure_level` の値。1 が正常、2 が警告、4 が危険
    init(level: Int32) {
        switch level {
        case 4:
            self = .critical

        case 2:
            self = .warning

        default:
            self = .normal
        }
    }
}

/// 負荷を測って記録し、項目を1つ返す。記録は `AppModel` の定期チェック（1分ごと）に合わせて増える
struct SystemLoadSource: ItemSource {
    let kind = MonitoredItem.Kind.systemLoad

    private let processList: any ProcessListReading
    private let readings: @Sendable () -> SystemReadings
    private let history: LoadHistory
    private let now: @Sendable () -> Date

    init(
        processList: any ProcessListReading = ProcessList(),
        readings: @escaping @Sendable () -> SystemReadings = { SystemReadings.read() },
        history: LoadHistory = LoadHistory(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processList = processList
        self.readings = readings
        self.history = history
        self.now = now
    }

    func items() async throws -> [MonitoredItem] {
        let processes = try await processList.read()
        let readings = readings()
        let date = now()
        let consumers = SystemLoad.Consumer.consumers(from: processes)
        // ps の値は数秒をならしたものなので、足すとコア数ぶんの上限をわずかに超えることがある
        let cpuPercent = min(consumers.reduce(0) { $0 + $1.cpuPercent }, Double(readings.coreCount) * 100)
        let sample = LoadSample(
            date: date,
            cpuPercent: cpuPercent,
            consumers: consumers.map { LoadSample.Consumer(name: $0.name, cpuPercent: $0.cpuPercent) }
        )
        let samples = await history.record(sample)
        let load = SystemLoad(
            cpuPercent: cpuPercent,
            coreCount: readings.coreCount,
            loadAverage: readings.loadAverage,
            thermalState: readings.thermalState,
            memoryPressure: readings.memoryPressure,
            consumers: consumers,
            history: samples
        )
        let status = LoadCheck.finding(in: load, now: date)?.status ?? .ok
        return [MonitoredItem(key: "load", name: kind.title, status: status, detail: .systemLoad(load))]
    }
}

/**
 1分ごとの記録を24時間分持つ。アプリを起動し直しても「さっきから続いている」が分かるよう、ファイルに JSON で残す。
 速度の履歴（UserDefaults）と違って数百 KB になり、毎分書き換えると UserDefaults の plist ごと書き直されるので、
 Application Support のファイルに分け、書くのも `saveInterval` ごとに間引く（終了直前の数分は失ってよい）。
 操作の直後の取り直しなどで間を置かずに呼ばれたら、最後の1件を置き換えて1分ごとの間隔を保つ
 */
actor LoadHistory {
    static let defaultFileURL = URL.applicationSupportDirectory.appending(path: "Breaker/load-history.json")
    static let retention: TimeInterval = 24 * 60 * 60
    /// 1件に残すアプリの数。続いている負荷の判定とグラフには上位だけで足りる
    static let consumerLimit = 5
    /// これより短い間隔で届いた記録は、最後の1件を置き換える
    static let minimumInterval: TimeInterval = 30
    static let saveInterval: TimeInterval = 10 * 60

    private let fileURL: URL
    private var samples: [LoadSample]
    private var lastSaveDate: Date?

    init(fileURL: URL = defaultFileURL) {
        self.fileURL = fileURL
        samples = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([LoadSample].self, from: $0) } ?? []
    }

    /// 記録を足し、古い順の全件を返す。上位のアプリだけを残す
    func record(_ sample: LoadSample) -> [LoadSample] {
        let trimmed = LoadSample(date: sample.date, cpuPercent: sample.cpuPercent, consumers: Array(sample.consumers.prefix(Self.consumerLimit)))
        if
            let last = samples.last,
            trimmed.date.timeIntervalSince(last.date) < Self.minimumInterval
        {
            samples.removeLast()
        }
        let oldestDate = trimmed.date.addingTimeInterval(-Self.retention)
        samples = (samples + [trimmed]).filter { $0.date >= oldestDate }
        if lastSaveDate.map({ trimmed.date.timeIntervalSince($0) >= Self.saveInterval }) ?? true {
            save()
            lastSaveDate = trimmed.date
        }
        return samples
    }

    /// 書けなくても記録はメモリに残り、判定とグラフは続けられるので、失敗は捨てる
    private func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
