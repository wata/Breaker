import Foundation

struct ShellOutput: Hashable, Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// サービスのテストで実際のコマンドを走らせずに出力を差し替えるための窓口
protocol ShellRunning: Sendable {
    func run(_ executable: String, arguments: [String]) async throws -> ShellOutput
}

/// 外部コマンドはすべてここを通す。シェルを介さず引数を配列で渡すので、ラベルやパスに空白や記号があっても解釈されない
struct ShellRunner: ShellRunning {
    func run(_ executable: String, arguments: [String]) async throws -> ShellOutput {
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
        async let stdout = Self.readAll(stdoutPipe.fileHandleForReading)
        async let stderr = Self.readAll(stderrPipe.fileHandleForReading)
        var status: Int32 = -1
        for await exitStatus in exitStatuses {
            status = exitStatus
        }
        return await ShellOutput(status: status, stdout: stdout, stderr: stderr)
    }

    /**
     `FileHandle.bytes` で両方のパイプを読むと、64KB を超える出力で子プロセスが書き込みのまま止まった。
     終端まで読むブロッキング呼び出しを協調スレッドプール外のスレッドで行う
     */
    private static func readAll(_ handle: FileHandle) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: String(decoding: handle.readDataToEndOfFile(), as: UTF8.self))
            }
        }
    }
}
