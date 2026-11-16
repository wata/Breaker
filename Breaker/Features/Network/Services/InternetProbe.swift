import Foundation

/// テストでインターネットへの到達を差し替えるための窓口
protocol InternetProbing: Sendable {
    func probe() async -> NetworkHealth.InternetAccess
}

/**
 macOS 自身がログイン画面（キャプティブポータル）の検出に使うのと同じページを取りに行く。
 ポータルは平文の http を書き換えて自分のページを返すので、https では検出できず（証明書エラーで「つながらない」になる）http で取る
 */
struct InternetProbe: InternetProbing {
    var url = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    var timeout: TimeInterval = 5

    func probe() async -> NetworkHealth.InternetAccess {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: url, delegate: RedirectBlocker())
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Self.makeAccess(statusCode: statusCode, body: String(decoding: data, as: UTF8.self))
        } catch {
            return .unreachable(reason: error.localizedDescription)
        }
    }

    /// 本物のページは本文に `Success` を含む 200。応答は返ったのにそれ以外（ログイン画面の 200・302・511 など）なら、途中で書き換えられたものとみなす
    static func makeAccess(statusCode: Int, body: String) -> NetworkHealth.InternetAccess {
        statusCode == 200 && body.contains("Success") ? .reachable : .captivePortal
    }
}

/**
 ポータルはログイン画面（http）へリダイレクトすることが多い。追うと ATS が平文の接続を止めて「つながらない」と区別できなくなるので、
 リダイレクトは追わずにその応答（302 など）で判定する
 */
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
