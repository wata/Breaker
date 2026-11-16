import Darwin
import Foundation

/**
 動いているプロセスの起動時刻。launchd は常駐ジョブ（KeepAlive）をいつ起動したかを持たないので、PID からカーネルに問い合わせる。
 外部コマンド（`ps`）を使わず、`sysctl` の `KERN_PROC_PID` で読む
 */
enum ProcessStartDate {
    /// プロセスが無い・読めないときは nil
    static func date(of pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard
            sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
            size > 0
        else {
            return nil
        }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
