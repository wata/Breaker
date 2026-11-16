import Testing
@testable import Breaker

struct InternetProbeTests {
    /// captive.apple.com が実際に返す本文
    @Test func success() {
        let body = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>\n"
        #expect(InternetProbe.makeAccess(statusCode: 200, body: body) == .reachable)
    }

    @Test func rewrittenPage() {
        #expect(InternetProbe.makeAccess(statusCode: 200, body: "<html><body>Please sign in</body></html>") == .captivePortal)
    }

    /// リダイレクトは追わないので、ログイン画面へ飛ばす 302 がそのまま来る
    @Test func redirect() {
        #expect(InternetProbe.makeAccess(statusCode: 302, body: "") == .captivePortal)
    }

    @Test func networkAuthenticationRequired() {
        #expect(InternetProbe.makeAccess(statusCode: 511, body: "") == .captivePortal)
    }
}
