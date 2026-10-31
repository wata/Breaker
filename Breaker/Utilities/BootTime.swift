import Foundation

enum BootTime {
    /// `sysctl kern.boottime`。取れなければ nil（走っていない検出で起動前の予定を除けなくなるだけ）
    static func current() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }
}
