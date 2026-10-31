import Foundation

enum AppEnvironment {
    /// 起動引数 `-BreakerSampleData YES` で渡す。引数は UserDefaults の引数ドメインに入るので、書き込まずに読める
    static let sampleDataKey = "BreakerSampleData"

    /**
     テストホストとして、またはプレビューとして起動されたとき。定期チェック・通知・ログイン項目のように
     実システムに触れる処理はここで止める（`xcodebuild test` のたびに launchctl や osascript を走らせない）
     */
    static func isIsolated(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /**
     README のスクリーンショットを、実際のジョブ名やパスを写さずに撮るためのモード。#Preview と同じ見本で一覧と詳細を出し、
     検出・定期チェック・通知・ログイン項目・設定の保存のどれも実システムに触れない。配布する Release では引数を渡されても効かせない
     */
    static func usesSampleData(_ defaults: UserDefaults = .standard, isDebugBuild: Bool = isDebugBuild) -> Bool {
        isDebugBuild && defaults.bool(forKey: sampleDataKey)
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
