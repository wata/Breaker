import Foundation

/// ストレージの値の書式。Finder と同じ書き方（1000 区切りの GB）にそろえる
extension StorageUsage {
    static func bytesText(_ bytes: Int64, locale: Locale = .current) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    /// サイドバーの行の2行目（`38 GB free`）
    func summary(locale: Locale = .current) -> String {
        String(
            localized: LocalizedStringResource("\(Self.bytesText(availableBytes, locale: locale)) free", comment: "Sidebar: free space of the startup disk, e.g. 38 GB free"),
            language: locale
        )
    }
}

extension StorageScan.Location {
    /// 増えた分を添える基準。走査ごとの小さな揺れ（キャッシュの出入り）まで「膨らんだ」と見せない
    static let notableGrowthBytes: Int64 = 1_000_000_000

    /// `+12 GB`。目立つほど増えていなければ nil
    func growthText(locale: Locale = .current) -> String? {
        if
            let growthBytes,
            growthBytes >= Self.notableGrowthBytes
        {
            "+\(StorageUsage.bytesText(growthBytes, locale: locale))"
        } else {
            nil
        }
    }
}

extension StorageLocation {
    var title: String {
        switch self {
        case .derivedData:
            String(localized: "Xcode DerivedData", comment: "Storage location: Xcode build products")

        case .xcodeArchives:
            String(localized: "Xcode Archives", comment: "Storage location: archived app builds")

        case .deviceSupport:
            String(localized: "Device Support Files", comment: "Storage location: Xcode's symbols for connected iPhones and other devices")

        case .simulators:
            String(localized: "Simulators", comment: "Storage location: iOS simulator devices and their caches")

        case .caches:
            String(localized: "Caches", comment: "Storage location: ~/Library/Caches")

        case .applicationSupport:
            String(localized: "App Data", comment: "Storage location: ~/Library/Application Support")

        case .nodeModules:
            "node_modules"

        // ツールの名前とフォルダの名前は訳さない
        case .userCache:
            "~/.cache"

        case .npm:
            String(localized: "npm Cache", comment: "Storage location: ~/.npm")

        case .pnpm:
            String(localized: "pnpm Store", comment: "Storage location: ~/Library/pnpm")

        case .bun:
            String(localized: "Bun Cache", comment: "Storage location: ~/.bun/install/cache")

        case .gradle:
            "Gradle"

        case .rust:
            String(localized: "Rust Toolchains and Crates", comment: "Storage location: ~/.cargo and ~/.rustup")

        case .goModules:
            String(localized: "Go Modules", comment: "Storage location: ~/go/pkg/mod")

        case .ollama:
            String(localized: "Ollama Models", comment: "Storage location: ~/.ollama")

        case .androidSDK:
            String(localized: "Android SDK", comment: "Storage location: Android SDK and emulators")
        }
    }
}
