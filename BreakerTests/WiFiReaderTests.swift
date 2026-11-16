import CoreWLAN
import Testing
@testable import Breaker

struct WiFiReaderTests {
    @Test func bands() {
        #expect(WiFiReader.band(.band2GHz) == .twoPointFourGigahertz)
        #expect(WiFiReader.band(.band5GHz) == .fiveGigahertz)
        #expect(WiFiReader.band(.band6GHz) == .sixGigahertz)
        #expect(WiFiReader.band(.bandUnknown) == .unknown)
    }

    @Test func channelWidths() {
        #expect(WiFiReader.megahertz(.width20MHz) == 20)
        #expect(WiFiReader.megahertz(.width40MHz) == 40)
        #expect(WiFiReader.megahertz(.width80MHz) == 80)
        #expect(WiFiReader.megahertz(.width160MHz) == 160)
        #expect(WiFiReader.megahertz(.widthUnknown) == nil)
    }

    @Test func phyModes() {
        #expect(WiFiReader.name(of: .mode11n) == "802.11n")
        #expect(WiFiReader.name(of: .mode11ac) == "802.11ac")
        #expect(WiFiReader.name(of: .mode11ax) == "802.11ax")
        #expect(WiFiReader.name(of: .mode11be) == "802.11be")
        #expect(WiFiReader.name(of: .modeNone) == nil)
    }
}
