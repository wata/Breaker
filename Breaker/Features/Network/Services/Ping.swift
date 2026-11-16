import Foundation

/// NetworkSource のテストで実際に ping を打たずに結果を差し替えるための窓口
protocol Pinging: Sendable {
    /// キャンセル以外では投げない。測れなかったときも受信0の結果を返す（理由は `Ping` を参照）
    func ping(_ host: String) async throws -> NetworkHealth.PingResult
}

/**
 `ping` で宛先に10回送り、ロス率と平均の往復時間を測る。
 名前を引けない・時間切れ・出力を読めないといった失敗も「応答が1つも確かめられなかった」ものとして受信0で返す。
 判定はルーター・外部の宛先とも受信0かどうかだけを見ればよく、失敗を別に扱う分岐を持たずに済む。
 結果が nil なのは、前提（経路・ルーターのアドレス）が無くて測らなかったときだけにする
 */
struct Ping: Pinging {
    private static let executable = "/sbin/ping"
    private static let count = 10
    private static let interval = "0.2"
    /// ping 自身の打ち切り（`-t`、秒）。10回を 0.2 秒間隔で送ると2秒ほどで終わるので、遅い応答を待つ分の余裕を持たせる
    private static let deadlineSeconds = 4
    /// ping が `-t` で終わらないところで止まっても判定を待たせないよう、外側でも打ち切る
    private static let timeout = Duration.seconds(6)

    private let shell: any ShellRunning

    init(shell: any ShellRunning = ShellRunner()) {
        self.shell = shell
    }

    func ping(_ host: String) async throws -> NetworkHealth.PingResult {
        let arguments = ["-q", "-c", "\(Self.count)", "-i", Self.interval, "-t", "\(Self.deadlineSeconds)", host]
        let summary: PingOutput.Summary
        do {
            let output = try await shell.run(Self.executable, arguments: arguments, timeout: Self.timeout)
            summary = try PingOutput.parse(stdout: output.stdout, status: output.status)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return NetworkHealth.PingResult(destination: host, receivedCount: 0, lossRate: 1, averageMilliseconds: nil)
        }
        return NetworkHealth.PingResult(
            destination: host,
            receivedCount: summary.received,
            lossRate: summary.packetLossPercent / 100,
            averageMilliseconds: summary.averageMilliseconds
        )
    }
}
