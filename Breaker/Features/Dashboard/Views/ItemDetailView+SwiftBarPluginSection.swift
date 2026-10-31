import SwiftUI

extension ItemDetailView {
    struct SwiftBarPluginSection: View {
        let plugin: MonitoredItem.SwiftBarPlugin
        let isLocked: Bool
        let perform: (ItemAction) -> Void

        var body: some View {
            Section("SwiftBar Plugin") {
                PathRow(title: "File", url: plugin.fileURL, isLocked: isLocked, perform: perform)

                LabeledContent(
                    "Refresh Interval",
                    value: plugin.refreshInterval.map { Schedule.intervalText(seconds: Int($0)) } ?? String(localized: "No automatic refresh")
                )
            }
        }
    }
}
