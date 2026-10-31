import Foundation

/**
 設定で選んだ Mac アプリ。/Applications にあるものと起動中のものを合わせる。何も選んでいなければ出さない。
 Mac で動かしている iPhone / iPad アプリは常駐させるものではないので含めない
 */
struct MonitoredAppSource: ItemSource {
    let kind = MonitoredItem.Kind.monitoredApp

    /// 設定画面で選んだ Bundle ID の配列（選んだ順）を UserDefaults に入れておくキー
    static let bundleIDsKey = "monitoredAppBundleIDs"

    private let selectedBundleIDs: @Sendable () -> [String]
    private let applicationsDirectory: URL
    private let runningApps: RunningApp.Provider

    /// `AppModel` は起動中ずっと同じ Source を使い続けるので、設定で選び直した内容が次の更新から効くよう選択は毎回読む
    init(
        bundleIDs: @escaping @Sendable () -> [String] = { MonitoredAppSource.selectedBundleIDs(in: .standard) },
        applicationsDirectory: URL = URL(filePath: "/Applications", directoryHint: .isDirectory),
        runningApps: @escaping RunningApp.Provider = RunningApp.systemProvider
    ) {
        selectedBundleIDs = bundleIDs
        self.applicationsDirectory = applicationsDirectory
        self.runningApps = runningApps
    }

    func items() async throws -> [MonitoredItem] {
        let bundleIDs = Set(selectedBundleIDs().filter { $0 != Self.ownBundleID })
        guard !bundleIDs.isEmpty else {
            return []
        }
        let installed = try FileManager.default
            .contentsOfDirectory(at: applicationsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.pathExtension == "app" }
            .reduce(into: [String: URL]()) { result, url in
                guard let bundleID = Self.bundleID(of: url) else { return }
                result[bundleID] = url
            }
            .filter { bundleIDs.contains($0.key) }
        let running = await runningApps()
            .filter { bundleIDs.contains($0.bundleID) && Self.isMacApp($0.bundleURL) }
            .reduce(into: [String: RunningApp]()) { $0[$1.bundleID] = $1 }
        return Set(installed.keys).union(running.keys).map { bundleID in
            let app = running[bundleID]
            let appURL = app?.bundleURL ?? installed[bundleID] ?? applicationsDirectory
            return MonitoredItem(
                key: bundleID,
                name: installed[bundleID].map { $0.deletingPathExtension().lastPathComponent } ?? app?.name ?? bundleID,
                status: status(isRunning: app != nil, appURL: appURL),
                detail: .monitoredApp(.init(bundleID: bundleID, appURL: appURL, isRunning: app != nil))
            )
        }
    }

    /**
     起動していないだけでは異常にしない。ログイン項目に登録されているかを確実に判定する手段がなく、
     「起動する設定ではないアプリ」まで異常になると通知がノイズになるため
     */
    func status(isRunning: Bool, appURL: URL) -> ItemStatus {
        if !isRunning {
            return .inactive(reason: String(localized: "Not running", comment: "Reason shown for a monitored app that isn't running"))
        }
        if !appURL.path(percentEncoded: false).isPath(under: applicationsDirectory.path(percentEncoded: false)) {
            return .warning(reason: String(localized: "Running from outside /Applications"), note: appURL.path(percentEncoded: false))
        }
        return .running
    }
}

extension MonitoredAppSource {
    /// 自分自身は常に起動中なので監視しても意味がない。設定画面でも選べないようにする
    static let ownBundleID = Bundle.main.bundleIdentifier

    static func selectedBundleIDs(in defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: bundleIDsKey) ?? []
    }

    /**
     ウィジェットなどの拡張（.appex）も起動中アプリとして現れるので、アプリ本体だけにする。
     Mac で動く iPhone / iPad アプリは `…/Wrapper/<名前>.app` から起動される（推測: 実機ではそのウィジェットが
     `/private/var/folders/…/Wrapper/<名前>.app/PlugIns/…appex` だった）
     */
    private static func isMacApp(_ bundleURL: URL?) -> Bool {
        if let bundleURL {
            return bundleURL.pathExtension == "app" && bundleURL.deletingLastPathComponent().lastPathComponent != "Wrapper"
        } else {
            return true
        }
    }

    /// Mac で動く iPhone / iPad アプリは `Contents/Info.plist` がなく（`WrappedBundle/Info.plist` にある）、ここで nil になる
    static func bundleID(of appURL: URL) -> String? {
        guard
            let data = try? Data(contentsOf: appURL.appending(path: "Contents/Info.plist")),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }
}
