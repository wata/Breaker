import Foundation
import Testing
@testable import Breaker

/// 詳細とサイドバーで共有する書式。数値の書き方がロケールに従うことも確かめる
struct NetworkHealthDisplayTests {
    private static let english = Locale(identifier: "en_US")
    private static let japanese = Locale(identifier: "ja_JP")
    private static let german = Locale(identifier: "de_DE")

    @Test func speedIsWholeMegabitsAboveTen() {
        #expect(NetworkHealth.speedText(bitsPerSecond: 146_000_000, locale: Self.english) == "146 Mbps")
        #expect(NetworkHealth.speedText(bitsPerSecond: 146_400_000, locale: Self.japanese) == "146 Mbps")
        #expect(NetworkHealth.speedText(bitsPerSecond: 1_234_000_000, locale: Self.english) == "1,234 Mbps")
        #expect(NetworkHealth.speedText(megabitsPerSecond: 864, locale: Self.english) == "864 Mbps")
    }

    /// 遅い回線の差が整数に丸めて消えないよう、10 Mbps 未満は小数1桁まで出す
    @Test func slowSpeedKeepsOneFractionDigit() {
        #expect(NetworkHealth.speedText(bitsPerSecond: 4_260_000, locale: Self.english) == "4.3 Mbps")
        #expect(NetworkHealth.speedText(bitsPerSecond: 4_260_000, locale: Self.german) == "4,3 Mbps")
        #expect(NetworkHealth.speedText(bitsPerSecond: 3_000_000, locale: Self.english) == "3 Mbps")
    }

    @Test func latencyHasOneFractionDigitBelowTen() {
        #expect(NetworkHealth.latencyText(milliseconds: 3.42, locale: Self.english) == "3.4 ms")
        #expect(NetworkHealth.latencyText(milliseconds: 3, locale: Self.english) == "3.0 ms")
        #expect(NetworkHealth.latencyText(milliseconds: 3.42, locale: Self.german) == "3,4 ms")
        #expect(NetworkHealth.latencyText(milliseconds: 12.8, locale: Self.english) == "13 ms")
    }

    @Test func packetLossIsWholePercent() {
        #expect(NetworkHealth.packetLossText(0, locale: Self.english) == "0% loss")
        #expect(NetworkHealth.packetLossText(0.2, locale: Self.english) == "20% loss")
    }

    @Test func signalAndResponsiveness() {
        #expect(NetworkHealth.powerText(decibelMilliwatts: -52, locale: Self.english) == "-52 dBm")
        #expect(NetworkHealth.signalToNoiseText(decibels: 42, locale: Self.english) == "42 dB")
        #expect(NetworkHealth.responsivenessText(1027, locale: Self.english) == "1,027 RPM")
    }

    @Test func measuredDateIsRelative() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let date = now.addingTimeInterval(-20 * 60)
        #expect(MonitoredItem.relativeDateText(date, now: now, locale: Self.english) == "20 min. ago")
        #expect(MonitoredItem.relativeDateText(date, now: now, locale: Self.japanese) == "20 分前")
    }

    @Test func channelShowsBandAndWidth() {
        #expect(Self.wifi(band: .fiveGigahertz, channelWidth: 80).channelText(locale: Self.english) == "36 (80 MHz)")
        #expect(Self.wifi(band: .twoPointFourGigahertz, channelWidth: nil).channelText(locale: Self.english) == "36")
        #expect(Self.wifi(band: .unknown, channelWidth: nil).channelText(locale: Self.english) == "36")
    }

    @Test func standardUsesGenerationName() {
        #expect(Self.wifi(phyMode: "802.11ax").standardText(locale: Self.english) == "Wi-Fi 6 (802.11ax)")
        #expect(Self.wifi(band: .sixGigahertz, phyMode: "802.11ax").standardText(locale: Self.english) == "Wi-Fi 6E (802.11ax)")
        #expect(Self.wifi(phyMode: "802.11be").standardText(locale: Self.english) == "Wi-Fi 7 (802.11be)")
        #expect(Self.wifi(phyMode: "802.11ac").standardText(locale: Self.english) == "Wi-Fi 5 (802.11ac)")
        #expect(Self.wifi(phyMode: "802.11g").standardText(locale: Self.english) == "802.11g")
        #expect(Self.wifi(phyMode: nil).standardText(locale: Self.english) == nil)
    }

    @Test func summaryJoinsDownloadAndLatency() {
        let health = MonitoredItem.sampleNetwork.networkHealth
        #expect(health?.summary(locale: Self.english) == "↓146 Mbps · Latency 13 ms")
    }

    @Test func summaryLabelsLatencyInJapanese() {
        let health = MonitoredItem.sampleNetwork.networkHealth
        #expect(health?.summary(locale: Locale(identifier: "ja_JP")) == "↓146 Mbps · 遅延 13 ms")
    }

    /// 正常なネットワークの行は、前回・次回の代わりに要約を出す
    @Test func sidebarRowShowsSummaryWhenHealthy() {
        #expect(MonitoredItem.sampleNetwork.rowDetail(now: .now, showsKind: false, locale: Self.english) == "↓146 Mbps · Latency 13 ms")
    }

    private static func wifi(band: NetworkHealth.WiFiInfo.Band = .fiveGigahertz, channelWidth: Int? = 80, phyMode: String? = "802.11ax") -> NetworkHealth.WiFiInfo {
        NetworkHealth.WiFiInfo(
            interfaceName: "en0",
            ssid: nil,
            rssi: -52,
            noise: -94,
            channelNumber: 36,
            band: band,
            channelWidth: channelWidth,
            phyMode: phyMode,
            transmitRate: 864
        )
    }
}
