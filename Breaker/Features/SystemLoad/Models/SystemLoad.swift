import Foundation

/**
 ある時点の Mac の負荷。チェックごとに作り直し、項目の詳細として持つ。
 CPU はどれもアクティビティモニタと同じ「1コアを使い切って 100」の % にそろえる（利用者の判断）。Mac 全体に対する割合にすると、
 1コアを使い切って止まらないアプリが 10 コアの Mac では「10%」になり、暴走しているように読めなかった
 */
struct SystemLoad: Hashable, Sendable {
    /// `ProcessInfo.ThermalState` を Sendable な値で持つ。serious 以上で macOS が CPU を絞る
    enum ThermalState: Hashable, Sendable {
        case nominal
        case fair
        case serious
        case critical
    }

    /// `kern.memorystatus_vm_pressure_level`。アクティビティモニタの「メモリプレッシャー」の緑・黄・赤にあたる
    enum MemoryPressure: Hashable, Sendable {
        case normal
        case warning
        case critical
    }

    /// CPU を使っているアプリ（.app の中の補助プロセスもまとめる）か、アプリに入っていないプロセス
    struct Consumer: Hashable, Sendable {
        let name: String
        /// アプリならその .app のパス。アイコンを出すのに使う
        let bundlePath: String?
        /// 1コアを使い切って 100
        let cpuPercent: Double
    }

    let cpuPercent: Double
    let coreCount: Int
    /// 直近1分の平均。コア数より大きいと、CPU を待っている処理がある
    let loadAverage: Double
    let thermalState: ThermalState
    let memoryPressure: MemoryPressure
    /// CPU を使っている順
    let consumers: [Consumer]
    /// 古い順。今の値（`cpuPercent`・`consumers`）も最後の1件として入っている
    let history: [LoadSample]
}

/// 1分ごとの記録。24時間分を残してグラフに描き、続いている負荷の判定に使う
struct LoadSample: Codable, Hashable, Sendable {
    struct Consumer: Codable, Hashable, Sendable {
        let name: String
        let cpuPercent: Double
    }

    let date: Date
    let cpuPercent: Double
    /// 使っている順に `LoadHistory.consumerLimit` 件まで
    let consumers: [Consumer]

    func cpuPercent(of name: String) -> Double {
        consumers.first { $0.name == name }?.cpuPercent ?? 0
    }
}
