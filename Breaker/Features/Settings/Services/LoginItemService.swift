import ServiceManagement

enum LoginItemStatus: Hashable, Sendable {
    case enabled
    /// 登録はしたが、システム設定の「ログイン項目」で利用者が許可するまで起動しない
    case requiresApproval
    case disabled
}

/// テストやプレビューで実際にログイン項目へ登録しないよう、`SMAppService` の使う部分だけを切り出す
@MainActor
protocol LoginItemManaging {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// このアプリ自身（`SMAppService.mainApp`）をログイン項目として登録・解除する
@MainActor
struct LoginItemService: LoginItemManaging {
    /// 未登録（`notRegistered`）と、署名や置き場所の都合で見つからない（`notFound`）はどちらも「起動しない」として扱う
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            .enabled

        case .requiresApproval:
            .requiresApproval

        case .notRegistered, .notFound:
            .disabled

        @unknown default:
            .disabled
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
