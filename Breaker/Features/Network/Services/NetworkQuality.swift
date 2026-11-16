import Foundation

/// SpeedTestScheduler のテストで実際に計測せず（約300MB 通信する）に結果を差し替えるための窓口
protocol SpeedTesting: Sendable {
    /// 計測の失敗は `.failed(reason:)` の記録で返し、投げるのはキャンセルのときだけ
    func measure() async throws -> SpeedTestRecord
}

/// `networkQuality` で上りと下りの速度・応答性を測る
struct NetworkQuality: SpeedTesting {
    private static let executable = "/usr/bin/networkQuality"
    /// 計測の上限（`-M`、秒）。既定の計測は長く通信量も多いので、速度の目安が取れる短さに抑える
    private static let maximumRunSeconds = 10
    /**
     `-M` は計測そのものの上限でしかなく、サーバーにつながる前に固まると networkQuality は終わらない。
     以前 Node の速度計測ツールがハングしたまま溜まっていった事故があったので、外側でも必ず打ち切る
     */
    private static let timeout = Duration.seconds(30)

    private let shell: any ShellRunning
    /// テストで計測の終了時刻を固定できるよう、今の時刻の取り方を受け取る
    private let now: @Sendable () -> Date

    init(shell: any ShellRunning = ShellRunner(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.shell = shell
        self.now = now
    }

    func measure() async throws -> SpeedTestRecord {
        let output: ShellOutput
        do {
            output = try await shell.run(Self.executable, arguments: ["-c", "-M", "\(Self.maximumRunSeconds)"], timeout: Self.timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch ShellError.timedOut {
            return failure(String(localized: "networkQuality didn't finish within \(Int(Self.timeout.components.seconds)) seconds"))
        } catch {
            return failure(error.localizedDescription)
        }

        guard output.status == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return failure(
                message.isEmpty
                    ? String(localized: "networkQuality failed with exit code \(output.status)")
                    : String(localized: "networkQuality failed with exit code \(output.status): \(message)")
            )
        }
        guard let result = try? NetworkQualityOutput.parse(Data(output.stdout.utf8)) else {
            return failure(String(localized: "Couldn't read the output of networkQuality"))
        }
        let speed = SpeedTestRecord.Speed(
            downloadBitsPerSecond: result.downloadThroughput,
            uploadBitsPerSecond: result.uploadThroughput,
            responsiveness: result.responsiveness,
            baseRoundTripMilliseconds: result.baseRoundTripTime
        )
        return SpeedTestRecord(date: result.endDate ?? now(), outcome: .succeeded(speed))
    }

    private func failure(_ reason: String) -> SpeedTestRecord {
        SpeedTestRecord(date: now(), outcome: .failed(reason: reason))
    }
}
