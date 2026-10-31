import Foundation
import Testing
@testable import Breaker

/// 実コマンドを走らせず、引数に応じた出力を返す
final class StubShell: ShellRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let respond: @Sendable (Call, [Call]) -> ShellOutput
    private let lock = NSLock()
    private var recordedCalls = [Call]()

    init(respond: @escaping @Sendable (Call) -> ShellOutput) {
        self.respond = { call, _ in respond(call) }
    }

    /// 状態を持つコマンド（bootout の後の print など）を真似るため、これまでの呼び出し（今回を含む）も渡す
    init(respondWithHistory respond: @escaping @Sendable (Call, [Call]) -> ShellOutput) {
        self.respond = respond
    }

    convenience init(output: ShellOutput) {
        self.init { _ in output }
    }

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    func run(_ executable: String, arguments: [String]) async throws -> ShellOutput {
        let call = Call(executable: executable, arguments: arguments)
        let history = lock.withLock {
            recordedCalls.append(call)
            return recordedCalls
        }
        return respond(call, history)
    }
}

extension StubShell {
    /**
     launchctl の代わり。`print` はロード中なら exited の出力、未ロードなら 113 を返す。
     bootout の後は、`printsLoadedAfterBootout` 回だけまだ残っているように見せてから未ロードになる
     （launchd の bootout が非同期に終わるのを真似る）。print 以外はすべて成功する
     */
    static func launchctl(isLoaded: Bool, printsLoadedAfterBootout: Int = 0) -> StubShell {
        StubShell { call, history in
            guard call.arguments.first == "print" else {
                return ShellOutput(status: 0, stdout: "", stderr: "")
            }
            let isStillLoaded = if let bootout = history.lastIndex(where: { $0.arguments.first == "bootout" }) {
                history[(bootout + 1)...].count { $0.arguments.first == "print" } <= printsLoadedAfterBootout
            } else {
                isLoaded
            }
            return isStillLoaded
                ? ShellOutput(status: 0, stdout: (try? fixture("launchctl-print-exited")) ?? "", stderr: "")
                : ShellOutput(status: 113, stdout: "", stderr: "Could not find service")
        }
    }
}

func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "txt"))
    return try String(contentsOf: url, encoding: .utf8)
}

private final class BundleToken {}

/// テストごとに作って消す一時ディレクトリ
struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "BreakerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// テストごとに作って消す UserDefaults の suite。実際のアプリの設定に書き込まない
struct IsolatedDefaults: ~Copyable {
    let userDefaults: UserDefaults
    private let suiteName = "BreakerTests-\(UUID().uuidString)"

    init() throws {
        userDefaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}

/// `pmset -g log` の1行。種類は実データと同じく20桁にそろえてタブで区切る
func pmsetLine(_ date: Date, _ kind: String, _ message: String = "message", timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return formatter.string(from: date) + " " + kind.padding(toLength: max(20, kind.count), withPad: " ", startingAt: 0) + "\t" + message
}
