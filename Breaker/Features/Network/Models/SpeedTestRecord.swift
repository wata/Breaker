import Foundation

/**
 最後に networkQuality で測った結果。計測は通信量が多く間隔を空けて走らせるので、アプリを起動し直しても前回の結果を出せるよう
 UserDefaults に JSON で保存する
 */
struct SpeedTestRecord: Codable, Hashable, Sendable {
    enum Outcome: Codable, Hashable, Sendable {
        case succeeded(Speed)
        /// networkQuality が失敗した・出力を読めなかった。つながらないとは限らないので、項目の失敗にはしない
        case failed(reason: String)
    }

    struct Speed: Codable, Hashable, Sendable {
        let downloadBitsPerSecond: Double
        let uploadBitsPerSecond: Double
        /// 応答性（RPM、1分あたりの往復回数）。古い macOS や途中で打ち切った計測では出ないので nil
        let responsiveness: Double?
        /// 負荷をかけていないときの往復時間（ミリ秒）
        let baseRoundTripMilliseconds: Double?
    }

    let date: Date
    let outcome: Outcome

    /// 測れた速度。失敗した計測なら nil
    var speed: Speed? {
        if case .succeeded(let speed) = outcome {
            speed
        } else {
            nil
        }
    }
}
