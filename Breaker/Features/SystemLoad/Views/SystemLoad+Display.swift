import Foundation

/// 負荷の値の書式。詳細とサイドバーで同じ書き方にそろえるため、どれも `String` を返す
extension SystemLoad {
    /// `42%`・`170%`。1コアを使い切って 100%
    static func percentText(_ percent: Double, locale: Locale = .current) -> String {
        (percent / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// サイドバーの行の2行目（`CPU 42% · Xcode`）。いちばん使っているアプリを添えて、何が重いかを行だけで読めるようにする
    func summary(locale: Locale = .current) -> String {
        let cpu = String(
            localized: LocalizedStringResource("CPU \(Self.percentText(cpuPercent, locale: locale))", comment: "Sidebar: CPU usage of the whole Mac, e.g. CPU 42%"),
            language: locale
        )
        if let top = consumers.first {
            return "\(cpu) · \(top.name)"
        } else {
            return cpu
        }
    }
}

extension SystemLoad.ThermalState {
    var title: String {
        switch self {
        case .nominal, .fair:
            String(localized: "Normal", comment: "Thermal state of the Mac: not throttled")

        case .serious:
            String(localized: "Hot, CPU slowed down", comment: "Thermal state of the Mac: macOS throttles the CPU")

        case .critical:
            String(localized: "Very hot, CPU slowed down", comment: "Thermal state of the Mac: macOS throttles the CPU heavily")
        }
    }
}

extension SystemLoad.MemoryPressure {
    var title: String {
        switch self {
        case .normal:
            String(localized: "Normal", comment: "Memory pressure of the Mac: enough memory")

        case .warning:
            String(localized: "High", comment: "Memory pressure of the Mac: memory is getting tight")

        case .critical:
            String(localized: "Critical", comment: "Memory pressure of the Mac: memory is running out")
        }
    }
}
