import Foundation

/**
 開発でよく膨らむ場所。追加の許可（フルディスクアクセス、書類・ダウンロードなどのフォルダ、ほかのアプリのデータ）が要らない場所だけを選び、
 Breaker が許可を求めるダイアログを出さないようにする。そのため、ゴミ箱・ダウンロード・Docker のディスクイメージは測らない
 */
enum StorageLocation: String, Codable, CaseIterable, Sendable {
    case derivedData
    case xcodeArchives
    case deviceSupport
    case simulators
    case caches
    case applicationSupport
    case nodeModules
    /**
     パッケージマネージャやツールのキャッシュは、まとめると何が膨らんだかを指せず Finder で開く先も決まらないので、1つずつ分ける。
     実機では `~/.cache`（uv・pip・Hugging Face など）だけで数十 GB あった
     */
    case userCache
    case npm
    case pnpm
    case bun
    case gradle
    case rust
    case goModules
    case ollama
    case androidSDK

    /// ホームからの相対パス。`nodeModules` はホームの中を探すので空
    var relativePaths: [String] {
        switch self {
        case .derivedData:
            ["Library/Developer/Xcode/DerivedData"]

        case .xcodeArchives:
            ["Library/Developer/Xcode/Archives"]

        case .deviceSupport:
            ["iOS", "watchOS", "tvOS", "visionOS", "macOS"].map { "Library/Developer/Xcode/\($0) DeviceSupport" }

        case .simulators:
            ["Library/Developer/CoreSimulator/Devices", "Library/Developer/CoreSimulator/Caches"]

        case .caches:
            ["Library/Caches"]

        case .applicationSupport:
            ["Library/Application Support"]

        case .nodeModules:
            []

        case .userCache:
            [".cache"]

        case .npm:
            [".npm"]

        case .pnpm:
            ["Library/pnpm"]

        case .bun:
            [".bun/install/cache"]

        case .gradle:
            [".gradle"]

        case .rust:
            [".cargo", ".rustup"]

        case .goModules:
            ["go/pkg/mod"]

        case .ollama:
            [".ollama"]

        case .androidSDK:
            ["Library/Android/sdk", ".android/avd"]
        }
    }

    /// Finder で見せる場所。複数のフォルダをまとめた場所は、共通の親を見せる
    var revealRelativePath: String {
        switch self {
        case .deviceSupport:
            "Library/Developer/Xcode"

        case .simulators:
            "Library/Developer/CoreSimulator"

        case .nodeModules, .rust:
            ""

        case .androidSDK:
            "Library/Android"

        case .derivedData, .xcodeArchives, .caches, .applicationSupport, .userCache, .npm, .pnpm, .bun, .gradle, .goModules, .ollama:
            relativePaths[0]
        }
    }
}
