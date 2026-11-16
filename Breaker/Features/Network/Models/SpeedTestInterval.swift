import Foundation

/// 速度の自動計測の間隔。1回で約300MB 通信するので、利用者が通信量と鮮度を選べるようにする
enum SpeedTestInterval: String, CaseIterable, Codable, Sendable {
    case manual
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case threeHours
    case sixHours

    /// 設定画面で選んだ値の rawValue を UserDefaults に入れておくキー
    static let key = "speedTestInterval"
    static let defaultValue = SpeedTestInterval.oneHour

    /// nil は自動では測らないこと
    var duration: Duration? {
        switch self {
        case .manual: nil
        case .fifteenMinutes: .seconds(15 * 60)
        case .thirtyMinutes: .seconds(30 * 60)
        case .oneHour: .seconds(60 * 60)
        case .threeHours: .seconds(3 * 60 * 60)
        case .sixHours: .seconds(6 * 60 * 60)
        }
    }

    /// 前の版で保存した、今は無い値が入っていても既定に戻す
    static func selected(in defaults: UserDefaults) -> SpeedTestInterval {
        defaults.string(forKey: key).flatMap(SpeedTestInterval.init(rawValue:)) ?? defaultValue
    }

    static func save(_ interval: SpeedTestInterval, in defaults: UserDefaults) {
        defaults.set(interval.rawValue, forKey: key)
    }
}
