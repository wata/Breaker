import Combine
import Observation
import Sparkle

/**
 Sparkle の自動アップデート。`Info.plist` の `SUFeedURL`（GitHub の appcast.xml）を確かめ、Developer ID で署名した GitHub Release の zip に入れ替える。
 テストホストやプレビュー、見本データでは始めないので、更新の確認も Sparkle の画面も出ない（始めていない間は `canCheckForUpdates` が false のままで、メニューの項目も押せない）
 */
@MainActor
@Observable
final class AppUpdater {
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    init(startsUpdater: Bool = !AppEnvironment.isIsolated() && !AppEnvironment.usesSampleData()) {
        controller = SPUStandardUpdaterController(startingUpdater: startsUpdater, updaterDelegate: nil, userDriverDelegate: nil)
        // 確認中は false になる。メニューの項目を押せるかどうかに使うため、KVO で追う
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] canCheckForUpdates in
                // Sparkle はこの値をメインスレッドでしか変えない
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = canCheckForUpdates
                }
            }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
