import AppKit
import Synchronization

/**
 Mac がスリープから明けた時刻。ウインドウを閉じて常駐している間は App Nap で定期チェックのタイマーが大きく遅れることがあり、
 チェックの間隔から明けを推し量ると毎回を明けと取り違えるので、システムの知らせで知る
 */
final class WakeMonitor: Sendable {
    static let shared = WakeMonitor()

    private let wakeDate = Mutex<Date?>(nil)

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            wakeDate.withLock { $0 = Date() }
        }
    }

    /// 起動してから一度も明けていなければ nil
    var lastWakeDate: Date? {
        wakeDate.withLock { $0 }
    }
}
