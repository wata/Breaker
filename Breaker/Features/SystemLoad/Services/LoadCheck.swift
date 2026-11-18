import Foundation

/**
 負荷の判定。一時的な負荷（数分のビルドなど）では鳴らさず、放っておくと続く負荷（止まらないプロセス・熱・メモリ不足）だけを要確認にする。
 理由の文言には数値を入れない。通知は状態が変わったときに出すので、数値が変わるたびに通知が出てしまう
 */
enum LoadCheck {
    enum Finding: Hashable, Sendable {
        /// 熱で macOS が CPU を絞っている
        case thermalThrottling
        /// 同じアプリ（プロセス）が CPU を使い続けている
        case sustainedConsumer(name: String)
        case memoryShortage

        var status: ItemStatus {
            switch self {
            case .thermalThrottling:
                .warning(reason: String(localized: "Mac is hot and slowed down", comment: "Reason of the system load item when macOS throttles the CPU because of heat"))

            case .sustainedConsumer(let name):
                .warning(reason: String(localized: "\(name) keeps using the CPU", comment: "Reason of the system load item when one app or process has used a lot of CPU for a while, e.g. Xcode keeps using the CPU"))

            case .memoryShortage:
                .warning(reason: String(localized: "Memory is running low", comment: "Reason of the system load item when the memory pressure is critical"))
            }
        }
    }

    /// 続いているとみなす長さ。ふつうのビルドやアップデートの展開はこれより短く終わる
    static let sustainedWindow: TimeInterval = 10 * 60
    /// 使い続けているとみなす量（1コア＝100 の %）。1コアの半分を平均で使い続けるのは、待機中のアプリではまず無い
    static let sustainedPercent = 50.0
    /**
     判定に要る記録の件数。スリープ明けやアプリの起動直後で記録が少ないうちは、たまたま高い1〜2回で決めない。
     1分ごとに記録するので、10分の窓に8件あれば途切れていないとみなす
     */
    static let minimumSampleCount = 8
    /**
     窓の中で使っていた記録の割合。平均だけだと、数分だけ全力で走ったビルドも平均を押し上げて鳴ってしまうので、
     ほとんどの時間に使っていたことも求める
     */
    static let presenceRatio = 0.8

    /// 熱 → 使い続けているアプリ → メモリの順に、1つだけ返す。熱で絞られていると、ほかの値も熱のせいで悪く見える
    static func finding(in load: SystemLoad, now: Date) -> Finding? {
        if [.serious, .critical].contains(load.thermalState) {
            return .thermalThrottling
        }
        if let name = sustainedConsumer(in: load.history, now: now) {
            return .sustainedConsumer(name: name)
        }
        if load.memoryPressure == .critical {
            return .memoryShortage
        }
        return nil
    }

    /**
     窓の中の平均が基準を超え、かつ窓のほとんどの記録で基準の半分以上を使っていたアプリ。
     上下するアプリ（統計を取る常駐アプリなど）は半分の基準で途切れずに数え、短い山のビルドは使っていた記録が少ないので外れる
     */
    static func sustainedConsumer(in history: [LoadSample], now: Date) -> String? {
        let samples = history.filter { $0.date > now.addingTimeInterval(-sustainedWindow) && $0.date <= now }
        guard
            samples.count >= minimumSampleCount,
            let latest = samples.last
        else {
            return nil
        }
        let threshold = sustainedPercent
        return latest.consumers
            .filter { consumer in
                let presentCount = samples.count { $0.cpuPercent(of: consumer.name) >= threshold / 2 }
                return Double(presentCount) >= Double(samples.count) * presenceRatio
            }
            .map { consumer in (name: consumer.name, average: samples.reduce(0) { $0 + $1.cpuPercent(of: consumer.name) } / Double(samples.count)) }
            .filter { $0.average >= threshold }
            .max { $0.average < $1.average }?
            .name
    }

    /**
     使い続けているアプリが、いつから続けて使っているか。今から記録をさかのぼり、基準を下回った記録の次の時刻を返す。
     記録の残っている一番古いところまで続いていれば、その時刻を返す（「24時間以上前から」と読める）。
     判定は平均で決めるので、上下するアプリが1回だけ基準を下回っても途切れないよう、さかのぼる基準は半分にする
     */
    static func sinceDate(of name: String, in history: [LoadSample]) -> Date? {
        let threshold = sustainedPercent / 2
        return history.reversed()
            .prefix { $0.cpuPercent(of: name) >= threshold }
            .last?
            .date
    }
}

extension SystemLoad {
    /// 使い続けていると判定したアプリ。詳細とプロンプトで原因として指す
    var culprit: String? {
        if case .sustainedConsumer(let name) = LoadCheck.finding(in: self, now: history.last?.date ?? .now) {
            name
        } else {
            nil
        }
    }
}
