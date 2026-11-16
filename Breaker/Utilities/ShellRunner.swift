import Foundation

struct ShellOutput: Hashable, Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ShellError: LocalizedError, Equatable {
    case timedOut(executable: String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let executable):
            String(localized: "\(executable) didn't finish in time")
        }
    }
}

/// サービスのテストで実際のコマンドを走らせずに出力を差し替えるための窓口
protocol ShellRunning: Sendable {
    /// `timeout` を過ぎても終わらなければ子プロセスを止めて `ShellError.timedOut` を投げる。nil なら終わるまで待つ
    func run(_ executable: String, arguments: [String], timeout: Duration?) async throws -> ShellOutput
}

extension ShellRunning {
    func run(_ executable: String, arguments: [String]) async throws -> ShellOutput {
        try await run(executable, arguments: arguments, timeout: nil)
    }
}

/// 外部コマンドはすべてここを通す。シェルを介さず引数を配列で渡すので、ラベルやパスに空白や記号があっても解釈されない
struct ShellRunner: ShellRunning {
    /// SIGTERM を無視するコマンドもあるので、この間に終わらなければ SIGKILL で確実に止める
    private static let killDelay: Duration = .seconds(2)
    /// 子が終わってもパイプを継いだ孫が残ると終端が来ないので、この間に読み切れなければ打ち切る
    private static let drainGrace: Duration = .seconds(1)

    func run(_ executable: String, arguments: [String], timeout: Duration?) async throws -> ShellOutput {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 終了通知を取りこぼさないよう、起動前にハンドラを付けておく
        let (exitStatuses, exitContinuation) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { process in
            exitContinuation.yield(process.terminationStatus)
            exitContinuation.finish()
        }
        try process.run()

        // 片方のパイプが満杯になると子プロセスが書き込みで止まるので、stdout と stderr を並行して読む
        let stdout = PipeReader(stdoutPipe.fileHandleForReading)
        let stderr = PipeReader(stderrPipe.fileHandleForReading)
        // 呼び出し元がキャンセルされても子の終了（回収）までは見届けたいので、キャンセルを継がない Task で待つ
        let exit = Task {
            for await status in exitStatuses {
                return status
            }
            return Int32(-1)
        }
        let timer = timeout.map { timeout in
            Task {
                guard (try? await Task.sleep(for: timeout)) != nil else { return false }
                // 時間切れと同時に自然に終わったものは、止めていないので時間切れにしない
                return Self.stop(process)
            }
        }

        let status = await withTaskCancellationHandler {
            await exit.value
        } onCancel: {
            _ = Self.stop(process)
        }
        timer?.cancel()
        let timedOut = await timer?.value ?? false

        if timedOut || Task.isCancelled {
            stdout.stop()
            stderr.stop()
            _ = await (stdout.text, stderr.text)
            if timedOut {
                throw ShellError.timedOut(executable: executable)
            }
            throw CancellationError()
        }

        let drain = Task {
            guard (try? await Task.sleep(for: Self.drainGrace)) != nil else { return }
            stdout.stop()
            stderr.stop()
        }
        defer { drain.cancel() }
        return await ShellOutput(status: status, stdout: stdout.text, stderr: stderr.text)
    }

    /// 止めに行ったら true。もう終わっていたら何もしない
    private static func stop(_ process: Process) -> Bool {
        guard process.isRunning else { return false }
        let pid = process.processIdentifier
        process.terminate()
        Task {
            try? await Task.sleep(for: killDelay)
            // 回収済みなら pid が別のプロセスに再利用されているかもしれないので、まだ動いているときだけ送る
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
        return true
    }
}

/**
 パイプを終端まで読む。`FileHandle.bytes` で両方のパイプを読むと、64KB を超える出力で子プロセスが書き込みのまま止まった。
 ブロッキングの `readDataToEndOfFile` は孫がパイプを握ったままだと外から打ち切れないので、`stop()` で安全に止められる DispatchIO で読む
 */
private final class PipeReader: Sendable {
    private let channel: DispatchIO
    private let reading: Task<String, Never>

    init(_ handle: FileHandle) {
        let (chunks, continuation) = AsyncStream.makeStream(of: Data.self)
        channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: .global()) { _ in
            // FileHandle は解放時に記述子を閉じるので、DispatchIO が記述子を手放すまで持っておく
            withExtendedLifetime(handle) {}
        }
        channel.read(offset: 0, length: .max, queue: .global()) { done, data, _ in
            if let data, !data.isEmpty {
                continuation.yield(Data(data))
            }
            if done {
                continuation.finish()
            }
        }
        reading = Task {
            var data = Data()
            for await chunk in chunks {
                data.append(chunk)
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    var text: String {
        get async { await reading.value }
    }

    /// 読みかけの read を打ち切り、それまでに読めた分で `text` を返させる
    func stop() {
        channel.close(flags: .stop)
    }
}
