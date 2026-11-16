import Foundation
import Testing
@testable import Breaker

struct DNSResolverTests {
    @Test func resolved() {
        let lookup = DNSResolver.makeLookup(outcome: .finished(code: 0), elapsed: .milliseconds(134) + .microseconds(500))
        #expect(lookup == .resolved(milliseconds: 134.5))
    }

    @Test func unknownHost() {
        let lookup = DNSResolver.makeLookup(outcome: .finished(code: EAI_NONAME), elapsed: .milliseconds(10))
        #expect(lookup == .failed(reason: "nodename nor servname provided, or not known"))
    }

    @Test func timedOut() {
        let lookup = DNSResolver.makeLookup(outcome: .timedOut, elapsed: .seconds(3))
        #expect(lookup == .failed(reason: "Operation timed out"))
    }
}
