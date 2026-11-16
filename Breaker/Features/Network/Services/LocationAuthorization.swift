import AppKit
import CoreLocation

enum LocationAuthorizationStatus: Hashable, Sendable {
    case notDetermined
    case authorized
    /// 拒否された・制限されている。アプリからはもう尋ねられないので、システム設定で変えてもらう
    case denied
}

/// テストやプレビューで実際に許可を求めないよう、`CLLocationManager` の使う部分だけを切り出す
@MainActor
protocol LocationAuthorizing: AnyObject {
    var status: LocationAuthorizationStatus { get }
    /// 利用者が答えたら（尋ねられない状態ならすぐに）答えを返す
    func requestAuthorization() async -> LocationAuthorizationStatus
    func openSystemSettings()
}

/**
 Wi-Fi のネットワーク名（SSID）は位置情報の許可が無いと CoreWLAN から読めないので、そのためだけに許可を求める。
 位置そのものは使わない
 */
@MainActor
final class LocationAuthorization: NSObject, LocationAuthorizing, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    /// 許可のダイアログを出せないとき（アプリが前面にいない等）は答えが来ず、待ちが残る。待っている側は設定画面の操作だけなので、残しても害は無い
    private var waiting: [CheckedContinuation<LocationAuthorizationStatus, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    var status: LocationAuthorizationStatus {
        Self.status(of: manager.authorizationStatus)
    }

    func requestAuthorization() async -> LocationAuthorizationStatus {
        guard status == .notDetermined else {
            return status
        }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }

    /// delegate を付けた直後にも今の状態で呼ばれるので、まだ答えが無いあいだは待っている呼び出し元へ返さない
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = Self.status(of: manager.authorizationStatus)
        Task { @MainActor in
            guard status != .notDetermined else { return }
            let continuations = waiting
            waiting = []
            for continuation in continuations {
                continuation.resume(returning: status)
            }
        }
    }

    /// macOS では「使用中のみ」を求めても「常に」として許可されることがあるので、どちらも許可として扱う
    nonisolated static func status(of authorizationStatus: CLAuthorizationStatus) -> LocationAuthorizationStatus {
        switch authorizationStatus {
        case .notDetermined:
            .notDetermined

        case .authorizedAlways, .authorizedWhenInUse:
            .authorized

        case .denied, .restricted:
            .denied

        @unknown default:
            .denied
        }
    }
}
