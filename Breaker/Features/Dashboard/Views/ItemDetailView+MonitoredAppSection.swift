import SwiftUI

extension ItemDetailView {
    /// 起動しているかどうかはヘッダーの状態に出ているので、ここでは出さない
    struct MonitoredAppSection: View {
        let app: MonitoredItem.MonitoredApp
        let isLocked: Bool
        let perform: (ItemAction) -> Void

        var body: some View {
            // 要確認の節で理由の前に添える種類と同じ言葉にする
            Section(MonitoredItem.Kind.monitoredApp.shortTitle) {
                LabeledContent("Bundle ID") {
                    Text(app.bundleID)
                        .font(.Mono.regular)
                        .textSelection(.enabled)
                }

                PathRow(title: "Location", url: app.appURL, isLocked: isLocked, perform: perform)
            }
        }
    }
}
